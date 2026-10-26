import CryptoKit
import Darwin
import Foundation

public struct ModelCandidate: Codable, Identifiable, Sendable {
    public var id: String { fileName }
    public let fileName: String
    public let sizeBytes: Int64
    public let sha256: String
    public let role: String
    public let license: String
    public let qualityGate: String
    public let sourceURL: URL?
    public let sourceRevision: String?
    public let downloadEnabled: Bool

    public init(fileName: String, sizeBytes: Int64, sha256: String, role: String,
                license: String, qualityGate: String, sourceURL: URL? = nil,
                sourceRevision: String? = nil, downloadEnabled: Bool = false) {
        self.fileName = fileName; self.sizeBytes = sizeBytes; self.sha256 = sha256
        self.role = role; self.license = license; self.qualityGate = qualityGate
        self.sourceURL = sourceURL; self.sourceRevision = sourceRevision
        self.downloadEnabled = downloadEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case fileName, sizeBytes, sha256, role, license, qualityGate
        case sourceURL, sourceRevision, downloadEnabled
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        fileName = try values.decode(String.self, forKey: .fileName)
        sizeBytes = try values.decode(Int64.self, forKey: .sizeBytes)
        sha256 = try values.decode(String.self, forKey: .sha256)
        role = try values.decode(String.self, forKey: .role)
        license = try values.decode(String.self, forKey: .license)
        qualityGate = try values.decode(String.self, forKey: .qualityGate)
        sourceURL = try values.decodeIfPresent(URL.self, forKey: .sourceURL)
        sourceRevision = try values.decodeIfPresent(String.self, forKey: .sourceRevision)
        // Older generated/test catalogues must remain non-downloadable by default.
        downloadEnabled = try values.decodeIfPresent(Bool.self, forKey: .downloadEnabled) ?? false
    }
}
public struct ModelCatalogue: Decodable, Sendable {
    public let models: [ModelCandidate]
    public let releaseApproved: Bool
    public let defaultModel: String?
}

public enum ModelStore {
    public enum RecoveryError: Error, LocalizedError, Equatable, Sendable {
        case backupAlreadyExists, unsafeExistingEntry, existingFileExceedsBudget
        case preservationFailed, activationFailedPreviousRestored, activationFailedBackupPreserved
        public var errorDescription: String? {
            switch self {
            case .backupAlreadyExists:
                return "Eine Modellsicherung wartet bereits auf Prüfung. Sie wurde nicht überschrieben; bitte zuerst die vorhandene Sicherung klären."
            case .unsafeExistingEntry:
                return "Das vorhandene Modellziel ist keine reguläre Datei. Es wurde nicht verändert."
            case .existingFileExceedsBudget:
                return "Das vorhandene Modell überschreitet das begrenzte Sicherungsbudget. Es wurde nicht verändert."
            case .preservationFailed:
                return "Das bisherige Modell konnte nicht sicher als Wiederherstellungskopie erhalten werden. Es wurde nicht ersetzt."
            case .activationFailedPreviousRestored:
                return "Das neue Modell konnte nicht aktiviert werden. Das bisherige Modell wurde wiederhergestellt."
            case .activationFailedBackupPreserved:
                return "Die Aktivierung wurde unterbrochen. Das bisherige Modell bleibt als Wiederherstellungskopie erhalten; bitte den Modellordner prüfen."
            }
        }
    }
    public struct Installed: Sendable {
        public let url: URL
        public let candidate: ModelCandidate
        /// True only after import verifies and reuses an existing managed inode.
        /// This is per-import provenance, not identity of an already-loaded engine.
        /// New activation, same-hash recovery, and read-only restoration are false.
        public let reusedVerifiedFile: Bool
        init(url: URL, candidate: ModelCandidate, reusedVerifiedFile: Bool = false) {
            self.url = url; self.candidate = candidate
            self.reusedVerifiedFile = reusedVerifiedFile
        }
    }
    public static func importModel(_ source: URL, into directory: URL, candidates: [ModelCandidate]) throws -> Installed {
        try Task.checkCancellation()
        let attrs = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard attrs.isRegularFile == true, attrs.isSymbolicLink != true,
              let size = attrs.fileSize, candidates.contains(where: { $0.sizeBytes == Int64(size) })
        else { throw DictationError.modelMismatch }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".import-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw DictationError.modelInvalid
        }
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: temporary)
        do {
            defer { try? input.close(); try? output.close() }
            var copied = 0
            while let data = try input.read(upToCount: min(1024 * 1024, size - copied + 1)), !data.isEmpty {
                try Task.checkCancellation()
                copied += data.count
                guard copied <= size else { throw DictationError.modelMismatch }
                try output.write(contentsOf: data)
            }
            guard copied == size else { throw DictationError.modelMismatch }
        }
        // Verify the actual private copy, not an earlier snapshot of a mutable external file.
        let candidate = try verify(temporary, candidates: candidates)
        return try installVerifiedTemporary(temporary, candidate: candidate, in: directory,
            replacementBudget: candidates.map(\.sizeBytes).max() ?? candidate.sizeBytes)
    }

    /// Installs only a completed download staged in this managed directory. The
    /// caller must retain partial bytes on cancellation and pass this gate only
    /// after the bounded transfer completed; this method still verifies them.
    static func installVerifiedDownload(_ downloaded: URL, candidate: ModelCandidate,
                                        into directory: URL,
                                        beforeActivation: (@Sendable () throws -> Void)? = nil) throws -> Installed {
        try Task.checkCancellation()
        let expectedName = ".download-\(candidate.sha256).part"
        guard downloaded.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
              downloaded.lastPathComponent == expectedName else { throw DictationError.modelInvalid }
        let verified = try verify(downloaded, candidates: [candidate])
        let catalogueBudget = try Self.candidates().map(\.sizeBytes).max() ?? verified.sizeBytes
        try beforeActivation?()
        try Task.checkCancellation()
        return try installVerifiedTemporary(downloaded, candidate: verified, in: directory,
            replacementBudget: max(catalogueBudget, verified.sizeBytes))
    }

    private static func installVerifiedTemporary(_ temporary: URL, candidate: ModelCandidate,
                                                 in directory: URL, replacementBudget: Int64) throws -> Installed {
        let destination = directory.appendingPathComponent(candidate.sha256 + ".bin")
        try Task.checkCancellation()
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: temporary.path)
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destination.path) {
            let existing = try FileManager.default.attributesOfItem(atPath: destination.path)
            guard existing[.type] as? FileAttributeType == .typeRegular else {
                throw RecoveryError.unsafeExistingEntry
            }
            do {
                _ = try verify(destination, candidates: [candidate])
                // Reuse a valid existing inode; do not modify it or create a backup.
                return Installed(url: destination, candidate: candidate, reusedVerifiedFile: true)
            } catch DictationError.modelMismatch {
                let current = try FileManager.default.attributesOfItem(atPath: destination.path)
                guard current[.type] as? FileAttributeType == .typeRegular else {
                    throw RecoveryError.unsafeExistingEntry
                }
                guard let originalInode = existing[.systemFileNumber] as? NSNumber,
                      let currentInode = current[.systemFileNumber] as? NSNumber,
                      let originalVolume = existing[.systemNumber] as? NSNumber,
                      let currentVolume = current[.systemNumber] as? NSNumber,
                      originalInode == currentInode, originalVolume == currentVolume else {
                    throw RecoveryError.preservationFailed
                }
                guard let existingSize = current[.size] as? NSNumber,
                      existingSize.int64Value >= 0, existingSize.int64Value <= replacementBudget else {
                    throw RecoveryError.existingFileExceedsBudget
                }
                try Task.checkCancellation()
                try activateRecovery(temporary, replacing: destination, in: directory)
            }
        } else {
            // Exclusive rename also refuses a dangling link or a concurrently appearing entry.
            try Task.checkCancellation()
            try renameWithoutReplacing(temporary, to: destination)
        }
        return Installed(url: destination, candidate: candidate)
    }
    /// Read-only restoration of an explicit catalog selection. Never follows a
    /// user-supplied path or activates a recovery backup automatically.
    public static func restoreSelection(_ hash: String, in directory: URL,
                                        candidates: [ModelCandidate]) throws -> Installed {
        try Task.checkCancellation()
        guard let candidate = candidates.first(where: { $0.sha256 == hash }),
              hash.count == 64, hash.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw DictationError.modelMismatch
        }
        let url = directory.appendingPathComponent(hash + ".bin")
        let verified = try verify(url, candidates: [candidate])
        return Installed(url: url, candidate: verified)
    }
    /// A single managed backup for the entire model directory, not an accumulating history.
    public static func recoveryBackupURL(in directory: URL) -> URL {
        directory.appendingPathComponent(".model-recovery.bin")
    }
    private static func activateRecovery(_ temporary: URL, replacing destination: URL, in directory: URL) throws {
        let backup = recoveryBackupURL(in: directory)
        do {
            try renameWithoutReplacing(destination, to: backup)
        } catch let error as NSError {
            if error.domain == NSPOSIXErrorDomain && error.code == Int(EEXIST) {
                throw RecoveryError.backupAlreadyExists
            }
            throw RecoveryError.preservationFailed
        }
        do {
            // New inode at the model name; existing mmap/read handles keep the old inode.
            try renameWithoutReplacing(temporary, to: destination)
        } catch {
            do {
                // Never overwrite a concurrently created destination while attempting rollback.
                try renameWithoutReplacing(backup, to: destination)
            } catch {
                throw RecoveryError.activationFailedBackupPreserved
            }
            throw RecoveryError.activationFailedPreviousRestored
        }
    }
    /// Same-directory atomic no-overwrite rename on supported macOS filesystems.
    /// Recovery uses two such operations; it is not a power-loss-atomic multi-file transaction.
    private static func renameWithoutReplacing(_ source: URL, to destination: URL) throws {
        let code: Int32 = source.path.withCString { from in
            destination.path.withCString { to in
                if renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 { return 0 }
                return errno
            }
        }
        guard code == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
    }
    public static func candidates() throws -> [ModelCandidate] {
        try catalogue().models
    }
    public static func catalogue() throws -> ModelCatalogue {
        guard let url = Bundle.module.url(forResource: "candidates", withExtension: "json", subdirectory: "Resources")
        else { throw DictationError.configuration }
        return try JSONDecoder().decode(ModelCatalogue.self, from: Data(contentsOf: url))
    }
    /// Streaming hash off the UI thread; original models are never modified.
    public static func verify(_ url: URL, candidates: [ModelCandidate]) throws -> ModelCandidate {
        let resource = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
        guard resource.isRegularFile == true, resource.isSymbolicLink != true,
              let size = resource.fileSize else { throw DictationError.modelInvalid }
        let matching = candidates.filter { $0.sizeBytes == Int64(size) }
        guard !matching.isEmpty else { throw DictationError.modelMismatch }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hasher = SHA256()
        var bytes = 0
        while let block = try file.read(upToCount: 1024 * 1024), !block.isEmpty {
            try Task.checkCancellation()
            bytes += block.count
            guard bytes <= size else { throw DictationError.modelMismatch }
            hasher.update(data: block)
        }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard bytes == size, let candidate = matching.first(where: { $0.sha256 == hash })
        else { throw DictationError.modelMismatch }
        return candidate
    }
}
