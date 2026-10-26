import AppKit
import AVFoundation
import ClavuneCore
import CoreAudio
import CryptoKit
import Darwin
import Foundation

/// Explicit synthetic UI exercise. Native-panel QA is a separate opt-in which
/// shares only the real transcript panels/alerts; its data and preferences stay isolated.
@MainActor
final class FunctionalQAContext {
    enum Failure: Error { case notOptedIn, unsafeEntry, unsupportedAction }
    nonisolated static let transcript = "A quiet morning leaves room to think. The first idea becomes a clear sentence."
    nonisolated static let openedText = "A clear sentence begins with a simple idea.\n"

    let directory: URL
    let modelSelection: (candidate: ModelCandidate, url: URL)
    let capture: any CaptureServicing
    let inference: any InferenceServicing
    private let files: FunctionalQAFiles
    private let nativePanelMode: Bool
    private(set) var copiedText: String?
    private var cleaned = false

    init(configuration: AppLaunchConfiguration) throws {
        guard configuration.isFunctionalQA else { throw Failure.notOptedIn }
        let files = try FunctionalQAFiles(includeAudio: !configuration.isNativePanelQA)
        self.files = files; directory = files.directory
        nativePanelMode = configuration.isNativePanelQA
        // No weights exist at this URL and no operation ever opens it.
        let modelURL = directory.appendingPathComponent("synthetic-model-never-opened")
        let candidate = try JSONDecoder().decode(ModelCandidate.self, from: Data("""
            {"fileName":"Synthetic QA (no model)","sizeBytes":0,
             "sha256":"0000000000000000000000000000000000000000000000000000000000000000",
             "role":"synthetic-qa","license":"No model","qualityGate":"Scripted test output only"}
            """.utf8))
        modelSelection = (candidate, modelURL)
        capture = FunctionalQACapture()
        if configuration.isNativePanelQA {
            inference = FunctionalQAClosedInference()
        } else {
            inference = FunctionalQAInference(modelURL: modelURL, candidate: candidate)
        }
    }

    func environment(terminate: @escaping @MainActor () -> Void = { NSApp.terminate(nil) }) -> CoordinatorEnvironment {
        let files = self.files
        let nativePanels = nativePanelMode
        let chooseOpen: @MainActor (UILanguage) -> URL? = { ui in
            guard nativePanels else { return files.preferredTranscriptToOpen() }
            return NativeTranscriptDialogs.chooseOpen(ui: ui, root: files.directory,
                                                       accepts: files.acceptsOpenSelection)
        }
        let chooseSave: @MainActor (UILanguage) -> URL? = { ui in
            guard nativePanels else { return files.saved }
            return NativeTranscriptDialogs.chooseSave(ui: ui, root: files.directory,
                                                       accepts: files.acceptsSaveSelection)
        }
        return CoordinatorEnvironment(nowHostTime: { mach_absolute_time() }, secureInputEnabled: { false },
            permissionStatus: { .denied }, requestPermission: { false }, inputDevices: { [] },
            chooseModel: { nil }, makeCancellation: { try DecodeCancellation() },
            makeWatchdog: { _ in {} }, workspaceNotifications: nil, terminate: terminate,
            registerHotkey: { _, _ in throw Failure.unsupportedAction },
            quitWillAwaitAdmittedOperation: {}, quitWillUnloadInference: {},
            copyText: { [self] text in
                guard !cleaned, text.utf8.count <= TranscriptFileStore.maximumBytes else { return false }
                copiedText = text; return true
            },
            chooseTranscriptToOpen: chooseOpen, chooseTranscriptToSave: chooseSave,
            confirmTranscriptReplacement: { ui in
                nativePanels ? NativeTranscriptDialogs.confirmReplacement(ui: ui) : true
            },
            readTranscript: { try files.readTranscript($0) },
            writeTranscript: { try files.writeTranscript($0, to: $1) },
            confirmUnsavedReviewQuit: { ui in
                nativePanels ? NativeTranscriptDialogs.confirmQuit(ui: ui) : .cancel
            },
            chooseAudioToImport: { _ in nativePanels ? nil : files.audio },
            readAudio: { url, policy in
                guard !nativePanels else { throw AudioFileImporter.Failure.invalidFile }
                return try files.readAudio(url, policy: policy)
            })
    }

    func acceptsOpenSelection(_ url: URL) -> Bool { files.acceptsOpenSelection(url) }
    func acceptsSaveSelection(_ url: URL) -> Bool { files.acceptsSaveSelection(url) }

    /// Call only after the coordinator's admitted operations have drained.
    /// Preexisting unknown/replaced entries make cleanup fail closed. This owned
    /// 0700 QA root is not an OS sandbox against concurrent same-UID replacement.
    func cleanup() throws {
        try files.cleanup()
        cleaned = true
        copiedText = nil
    }
}

/// Only immutable, generated input bytes and one replaceable saved transcript.
/// Directory identity, regular-file identity and hashes are checked at each boundary.
private final class FunctionalQAFiles: @unchecked Sendable {
    struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
        let bytes: off_t
        let hash: String
    }
    let directory: URL
    var audio: URL { directory.appendingPathComponent("synthetic.wav") }
    var opened: URL { directory.appendingPathComponent("opened.txt") }
    var saved: URL { directory.appendingPathComponent("saved.txt") }
    private let lock = NSLock()
    private let directoryDevice: dev_t
    private let directoryInode: ino_t
    // closeOnDealloc also closes a directory opened by a throwing initializer.
    private let directoryHandle: FileHandle
    private var descriptor: Int32 { directoryHandle.fileDescriptor }
    private var identities: [String: Identity] = [:]
    private var cleaned = false

    init(includeAudio: Bool = true) throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("Clavune-FunctionalQA-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        directory = root
        var info = stat()
        guard lstat(root.path, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              info.st_uid == geteuid() else { throw FunctionalQAContext.Failure.unsafeEntry }
        directoryDevice = info.st_dev; directoryInode = info.st_ino
        let descriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw FunctionalQAContext.Failure.unsafeEntry }
        directoryHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            if includeAudio { try create(Self.wav(), named: "synthetic.wav") }
            try create(Data(FunctionalQAContext.openedText.utf8), named: "opened.txt")
        } catch {
            // Only entries made by this initializer are eligible for removal.
            for name in identities.keys { _ = unlinkat(descriptor, name, 0) }
            _ = rmdir(root.path)
            throw error
        }
    }
    private static func wav() -> Data {
        let count = 4_000, byteCount = UInt32(count * 2)
        var data = Data()
        func ascii(_ text: String) { data.append(contentsOf: text.utf8) }
        func u16(_ number: UInt16) { data.append(UInt8(truncatingIfNeeded: number)); data.append(UInt8(truncatingIfNeeded: number >> 8)) }
        func u32(_ number: UInt32) { for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8(truncatingIfNeeded: number >> shift)) } }
        ascii("RIFF"); u32(36 + byteCount); ascii("WAVEfmt "); u32(16); u16(1); u16(1)
        u32(16_000); u32(32_000); u16(2); u16(16); ascii("data"); u32(byteCount)
        for index in 0..<count { u16(UInt16(bitPattern: Int16((sin(Double(index) * .pi / 20) * 6_000).rounded()))) }
        return data
    }
    private func verifyDirectory() throws {
        guard !cleaned else { throw FunctionalQAContext.Failure.unsafeEntry }
        var path = stat(), opened = stat()
        guard lstat(directory.path, &path) == 0, fstat(descriptor, &opened) == 0,
              (path.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR), path.st_uid == geteuid(),
              path.st_dev == directoryDevice, path.st_ino == directoryInode,
              opened.st_dev == directoryDevice, opened.st_ino == directoryInode,
              directory.resolvingSymlinksInPath() == directory else { throw FunctionalQAContext.Failure.unsafeEntry }
    }
    private func identity(_ name: String) throws -> Identity {
        var info = stat()
        guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), info.st_size >= 0,
              info.st_size <= TranscriptFileStore.maximumBytes else { throw FunctionalQAContext.Failure.unsafeEntry }
        let fd = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw FunctionalQAContext.Failure.unsafeEntry }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_dev == info.st_dev, opened.st_ino == info.st_ino else {
            throw FunctionalQAContext.Failure.unsafeEntry
        }
        let data = try file.read(upToCount: TranscriptFileStore.maximumBytes + 1) ?? Data()
        var after = stat()
        guard data.count == Int(info.st_size), fstat(fd, &after) == 0,
              after.st_dev == info.st_dev, after.st_ino == info.st_ino, after.st_size == info.st_size else {
            throw FunctionalQAContext.Failure.unsafeEntry
        }
        return Identity(device: info.st_dev, inode: info.st_ino, bytes: info.st_size,
                        hash: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
    private func create(_ data: Data, named name: String) throws {
        let fd = openat(descriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw FunctionalQAContext.Failure.unsafeEntry }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try file.write(contentsOf: data); try file.close()
            identities[name] = try identity(name)
        } catch {
            try? file.close()
            _ = unlinkat(descriptor, name, 0)
            throw error
        }
    }
    private func verify(_ url: URL, name: String, mayBeAbsent: Bool = false) throws {
        try verifyDirectory()
        guard url.isFileURL, url == directory.appendingPathComponent(name),
              url.resolvingSymlinksInPath() == url else { throw FunctionalQAContext.Failure.unsafeEntry }
        if let expected = identities[name] {
            guard try identity(name) == expected else { throw FunctionalQAContext.Failure.unsafeEntry }
        } else {
            var info = stat()
            guard mayBeAbsent, fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) != 0,
                  errno == ENOENT else { throw FunctionalQAContext.Failure.unsafeEntry }
        }
    }
    func readAudio(_ url: URL, policy: ResourcePolicy) throws -> SessionPCM {
        lock.lock(); defer { lock.unlock() }
        try verify(url, name: "synthetic.wav")
        let pcm = try AudioFileImporter.read(url, policy: policy)
        try verify(url, name: "synthetic.wav")
        return pcm
    }
    func readTranscript(_ url: URL) throws -> String {
        lock.lock(); defer { lock.unlock() }
        let name = url == saved ? "saved.txt" : "opened.txt"
        try verify(url, name: name)
        let text = try TranscriptFileStore.read(url)
        try verify(url, name: name)
        return text
    }
    func preferredTranscriptToOpen() -> URL? {
        lock.lock(); defer { lock.unlock() }
        let name = identities["saved.txt"] == nil ? "opened.txt" : "saved.txt"
        let url = directory.appendingPathComponent(name)
        do { try verify(url, name: name); return url } catch { return nil }
    }
    func acceptsOpenSelection(_ url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        do { try verify(url, name: "opened.txt"); return true }
        catch { return false }
    }
    func acceptsSaveSelection(_ url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        do { try verify(url, name: "saved.txt", mayBeAbsent: true); return true }
        catch { return false }
    }
    func writeTranscript(_ text: String, to url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        try verify(url, name: "saved.txt", mayBeAbsent: true)
        try TranscriptFileStore.write(text, to: url)
        try verifyDirectory()
        let saved = try identity("saved.txt")
        let expected = Data(text.utf8)
        guard saved.bytes == off_t(expected.count),
              saved.hash == SHA256.hash(data: expected).map({ String(format: "%02x", $0) }).joined() else {
            throw FunctionalQAContext.Failure.unsafeEntry
        }
        identities["saved.txt"] = saved
    }
    func cleanup() throws {
        lock.lock(); defer { lock.unlock() }
        if cleaned { return }
        try verifyDirectory()
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        guard Set(names) == Set(identities.keys) else { throw FunctionalQAContext.Failure.unsafeEntry }
        for name in names { guard try identity(name) == identities[name] else { throw FunctionalQAContext.Failure.unsafeEntry } }
        for name in names { guard unlinkat(descriptor, name, 0) == 0 else { throw FunctionalQAContext.Failure.unsafeEntry } }
        try verifyDirectory()
        guard rmdir(directory.path) == 0 else { throw FunctionalQAContext.Failure.unsafeEntry }
        cleaned = true; identities.removeAll()
    }
}

private final class FunctionalQACapture: CaptureServicing, @unchecked Sendable {
    func start(session: UUID, deviceID: AudioDeviceID?, channel: Int, policy: ResourcePolicy,
               authorization: CaptureStartupGate, onFirstSample: @escaping @Sendable () -> Void,
               onProgress: @escaping @Sendable (Double, Float) -> Void,
               onFailure: @escaping @Sendable (DictationError) -> Void,
               onLimitReached: @escaping @Sendable (CaptureStopRequest) -> Void) async throws {
        throw DictationError.privacyBlocked
    }
    func stop(_ request: CaptureStopRequest) async throws -> CapturedAudio { throw DictationError.cancelled }
    func cancel(session: UUID?) async {}
}

private actor FunctionalQAInference: InferenceServicing {
    private let modelURL: URL
    private let candidate: ModelCandidate
    private var warm = false
    private var decoding = false
    private var generation: UInt64 = 0
    init(modelURL: URL, candidate: ModelCandidate) { self.modelURL = modelURL; self.candidate = candidate }
    func load(url: URL, candidate: ModelCandidate) async throws -> (warm: Bool, seconds: Double) {
        try Task.checkCancellation()
        guard !decoding else { throw DictationError.busy }
        guard url == modelURL, candidate.sha256 == self.candidate.sha256, candidate.sizeBytes == 0 else {
            throw DictationError.modelInvalid
        }
        let previous = warm
        if !warm { generation &+= 1 }
        warm = true
        return (previous, 0)
    }
    func transcribe(_ pcm: SessionPCM, language: LanguageMode, cancellation: DecodeCancellation,
                    policy: ResourcePolicy) async throws -> TranscriptionResult {
        guard warm, !pcm.samples.isEmpty, pcm.samples.count <= policy.maxSamples else { throw DictationError.noAudio }
        guard !decoding else { throw DictationError.busy }
        decoding = true
        defer { decoding = false }
        let admittedGeneration = generation
        // Deliberate bounded QA work, not a latency or quality measurement.
        try await Task.sleep(nanoseconds: 250_000_000)
        try Task.checkCancellation()
        guard warm, generation == admittedGeneration else { throw DictationError.cancelled }
        return TranscriptionResult(text: FunctionalQAContext.transcript, languageID: -1, decodeSeconds: 0)
    }
    func unload() async { warm = false; generation &+= 1 }
}

/// Native-dialog QA has no audio entrypoint. Even an accidental coordinator
/// call cannot load or decode the synthetic fixture service.
private actor FunctionalQAClosedInference: InferenceServicing {
    func load(url: URL, candidate: ModelCandidate) async throws -> (warm: Bool, seconds: Double) {
        throw DictationError.privacyBlocked
    }
    func transcribe(_ pcm: SessionPCM, language: LanguageMode, cancellation: DecodeCancellation,
                    policy: ResourcePolicy) async throws -> TranscriptionResult {
        throw DictationError.privacyBlocked
    }
    func unload() async {}
}
