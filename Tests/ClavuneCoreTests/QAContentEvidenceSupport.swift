import AppKit
import CryptoKit
import Darwin
import Foundation
import XCTest

/// Static-content provenance, not a source-to-binary or motion certification.
/// Only the opt-in renderer invokes this helper; ordinary tests need no manifest.
struct QAContentSourceBinding: Codable {
    let sourceManifestSHA256: String
    let candidateSourceTreeSHA256: String
    let verifiedSourceFileCount: Int
    let testBundleExecutableSHA256: String
    let sourceToBinaryBinding: String

    private struct SourceManifest: Decodable {
        struct File: Decodable { let path: String; let bytes: Int; let sha256: String }
        let format: String
        let candidate_source_file_count: Int
        let candidate_source_tree_sha256: String
        let files: [File]
    }
    enum Failure: Error { case missingBinding, invalidHash, unsafePath, sourceMismatch, unsafeOutput, write }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func sourcePathIsAllowed(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, !path.contains("\\"), !path.contains(":"),
              !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") }) else { return false }
        return path == "Package.swift" || ["Config", "Sources", "Tests", "Scripts"].contains(String(parts[0]))
    }
    /// Foundation may spell the same macOS temporary location as /tmp or
    /// /private/tmp. POSIX realpath supplies one physical spelling for both.
    static func canonicalFileSystemPath(_ url: URL) throws -> String {
        guard url.isFileURL else { throw Failure.unsafePath }
        let resolved = url.withUnsafeFileSystemRepresentation { path -> UnsafeMutablePointer<CChar>? in
            guard let path else { return nil }
            return Darwin.realpath(path, nil)
        }
        guard let resolved else { throw Failure.unsafePath }
        defer { free(resolved) }
        return String(cString: resolved)
    }
    /// Component containment, never character-count slicing or string-prefix
    /// containment ("candidate-other" is not inside "candidate").
    static func sourceRelativePath(canonicalFilePath: String, canonicalRootPath: String) throws -> String {
        let root = (canonicalRootPath as NSString).pathComponents
        let file = (canonicalFilePath as NSString).pathComponents
        guard root.first == "/", file.count > root.count,
              Array(file.prefix(root.count)) == root else { throw Failure.unsafePath }
        let relative = file.dropFirst(root.count).joined(separator: "/")
        guard sourcePathIsAllowed(relative) else { throw Failure.unsafePath }
        return relative
    }
    /// Root aliases are normalized once; a symlink in any manifest-relative
    /// component remains forbidden, even when its destination is inside root.
    static func sourceFileURL(_ relative: String, canonicalRootPath: String) throws -> URL {
        guard sourcePathIsAllowed(relative) else { throw Failure.unsafePath }
        let components = relative.split(separator: "/")
        var checkedPath = canonicalRootPath
        for (index, component) in components.enumerated() {
            checkedPath += "/" + component
            var info = stat()
            let expectedType = index == components.count - 1 ? mode_t(S_IFREG) : mode_t(S_IFDIR)
            guard lstat(checkedPath, &info) == 0,
                  info.st_mode & mode_t(S_IFMT) == expectedType else { throw Failure.unsafePath }
        }
        let expected = canonicalRootPath + "/" + relative
        let url = URL(fileURLWithPath: expected)
        guard try canonicalFileSystemPath(url) == expected else { throw Failure.unsafePath }
        return url
    }
    /// Absolute parent locations are caller-selected; source-relative ancestors
    /// are verified separately below. No symlink leaf or special file is read.
    static func readRegular(_ url: URL) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.unsafePath }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw Failure.unsafePath
        }
        return try handle.readToEnd() ?? Data()
    }
    static func verify(environment: [String: String], testBundle: Bundle) throws -> Self {
        guard let manifestPath = environment["CLAVUNE_QA_RENDER_SOURCE_MANIFEST"],
              let expected = environment["CLAVUNE_QA_RENDER_SOURCE_MANIFEST_SHA256"],
              let executable = testBundle.executableURL else { throw Failure.missingBinding }
        guard isSHA256(expected) else { throw Failure.invalidHash }
        let manifestData = try readRegular(URL(fileURLWithPath: manifestPath))
        guard sha256(manifestData) == expected else { throw Failure.sourceMismatch }
        let manifest = try JSONDecoder().decode(SourceManifest.self, from: manifestData)
        guard manifest.format == "clavune-source-handoff-v1",
              manifest.candidate_source_file_count == manifest.files.count,
              isSHA256(manifest.candidate_source_tree_sha256) else { throw Failure.sourceMismatch }
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let canonicalRootPath = try canonicalFileSystemPath(sourceRoot)
        let root = URL(fileURLWithPath: canonicalRootPath, isDirectory: true)
        let paths = manifest.files.map(\.path)
        guard !paths.isEmpty, Set(paths).count == paths.count,
              paths.allSatisfy(sourcePathIsAllowed) else { throw Failure.unsafePath }
        let records = manifest.files.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
            .map { "\($0.path) \($0.sha256)\n" }.joined()
        guard sha256(Data(records.utf8)) == manifest.candidate_source_tree_sha256 else {
            throw Failure.sourceMismatch
        }
        // Exact selected-input inventory prevents an omitted new Swift/test file
        // from masquerading as a match to an older pinned manifest.
        var actual = Set(["Package.swift"])
        let manager = FileManager.default
        for folder in ["Config", "Sources", "Tests", "Scripts"] {
            guard let entries = manager.enumerator(at: root.appendingPathComponent(folder),
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]) else {
                throw Failure.unsafePath
            }
            for case let file as URL in entries {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw Failure.unsafePath }
                // Source-only handoffs never include local compiler/Python caches.
                // Tests can create these without changing selected source identity.
                if values.isDirectory == true && ["__pycache__", ".build", ".git"].contains(file.lastPathComponent) {
                    entries.skipDescendants(); continue
                }
                if file.pathExtension == "pyc" || file.lastPathComponent == ".DS_Store" { continue }
                if values.isRegularFile == true {
                    let canonicalFilePath = try canonicalFileSystemPath(file)
                    actual.insert(try sourceRelativePath(canonicalFilePath: canonicalFilePath,
                                                         canonicalRootPath: canonicalRootPath))
                } else if values.isDirectory != true { throw Failure.unsafePath }
            }
        }
        guard actual == Set(paths) else { throw Failure.sourceMismatch }
        for file in manifest.files {
            guard isSHA256(file.sha256) else { throw Failure.invalidHash }
            let url = try sourceFileURL(file.path, canonicalRootPath: canonicalRootPath)
            let bytes = try readRegular(url)
            guard bytes.count == file.bytes, sha256(bytes) == file.sha256 else { throw Failure.sourceMismatch }
        }
        return Self(sourceManifestSHA256: expected, candidateSourceTreeSHA256: manifest.candidate_source_tree_sha256,
            verifiedSourceFileCount: paths.count,
            testBundleExecutableSHA256: sha256(try readRegular(executable)),
            sourceToBinaryBinding: "pending-independent-clean-build-receipt")
    }
}

/// Fresh test-owned directory beneath one fixed /tmp namespace. openat +
/// O_EXCL/O_NOFOLLOW prevent overwriting prior images or following leaf aliases.
final class QAContentEvidenceOutput {
    let directory: URL
    private let handle: FileHandle
    init(path: String) throws {
        let requested = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let namespace = URL(fileURLWithPath: "/tmp/clavune-offscreen-evidence", isDirectory: true)
        let name = requested.lastPathComponent
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard requested.deletingLastPathComponent().path == namespace.path,
              !name.isEmpty, name.allSatisfy({ allowed.contains($0) }) else {
            throw QAContentSourceBinding.Failure.unsafeOutput
        }
        let temporaryRootPath = try QAContentSourceBinding.canonicalFileSystemPath(
            URL(fileURLWithPath: "/tmp", isDirectory: true))
        let temp = URL(fileURLWithPath: temporaryRootPath, isDirectory: true)
        let parent = Darwin.open(temporaryRootPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw QAContentSourceBinding.Failure.unsafeOutput }
        defer { Darwin.close(parent) }
        if mkdirat(parent, "clavune-offscreen-evidence", 0o700) != 0 && errno != EEXIST {
            throw QAContentSourceBinding.Failure.unsafeOutput
        }
        let namespaceFD = openat(parent, "clavune-offscreen-evidence", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard namespaceFD >= 0 else { throw QAContentSourceBinding.Failure.unsafeOutput }
        defer { Darwin.close(namespaceFD) }
        var info = stat()
        guard fstat(namespaceFD, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o7777 == 0o700,
              mkdirat(namespaceFD, name, 0o700) == 0 else { throw QAContentSourceBinding.Failure.unsafeOutput }
        let fd = openat(namespaceFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw QAContentSourceBinding.Failure.unsafeOutput }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        directory = temp.appendingPathComponent("clavune-offscreen-evidence").appendingPathComponent(name)
    }
    func write(_ data: Data, name: String) throws {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), name != ".", name != ".." else {
            throw QAContentSourceBinding.Failure.unsafeOutput
        }
        let fd = openat(handle.fileDescriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw QAContentSourceBinding.Failure.write }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        try file.write(contentsOf: data)
        guard fsync(fd) == 0 else { throw QAContentSourceBinding.Failure.write }
    }
}

struct QAContentRenderEvidence: Encodable {
    struct Image: Encodable {
        let file: String
        let sha256: String
        let bytes: Int
        let widthPoints: Double
        let heightPoints: Double
        let widthPixels: Int
        let heightPixels: Int
        let reduceMotion: Bool
    }
    let format = "clavune-static-content-evidence"
    let version = 1
    let source: QAContentSourceBinding
    let captureMethod = "NSView.cacheDisplay-owned-hidden-host"
    let syntheticDataOnly = true
    let isolationPolicy = "rejecting-capture-inference-system-boundaries; no-preferences; no-model-selected"
    let statisticsReferenceTimeUnix: Int = 1_792_756_800
    let statisticsPeriod = "last7Days-rolling-604800-seconds-end-exclusive"
    let motionCapture = "notCaptured"
    let animationCalibration = "notRun-endpoint-only-evidence"
    let realWindowAndAccessibilityAcceptance = "pending-local-review"
    let testResult = "not-encoded-consult-matching-xcresult"
    let forbiddenBoundaryCalls: [String]
    let images: [Image]
}
