import Darwin
import Foundation

/// POSIX mode bits do not describe macOS extended ACL grants. Require no
/// extended entries on the private journal boundary, using the opened inode
/// rather than following a second pathname. An ACL query error fails closed.
enum LocalMetricsACL {
    static func isAbsent(on fd: Int32) -> Bool {
        errno = 0
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
            return errno == ENOENT
        }
        // Even an empty ACL object is conservatively treated as non-private.
        // Darwin reports ENOENT when no extended ACL exists at all.
        acl_free(UnsafeMutableRawPointer(acl))
        return false
    }
}

/// Content-free local usage event. Never add transcript text, audio, paths,
/// clipboard contents, window titles, or arbitrary error descriptions here.
public struct LocalMetricsEvent: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case sessionStarted, transcriptionCompleted, sessionFailed, sessionCancelled
        case sessionInterrupted, reviewAction
    }
    public enum Source: String, Codable, Sendable { case microphone, audioFile, transcriptFile }
    public enum ReviewAction: String, Codable, Sendable { case copy, save, open, discard, cancel }

    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
    public let eventID: UUID
    public let sessionID: UUID
    public let timestamp: Date
    public let kind: Kind
    public let source: Source
    public let requestedLanguage: String?
    /// Populated only when Auto mode actually runs language detection.
    public let detectedLanguageID: Int?
    public let modelFileName: String?
    public let modelSHA256: String?
    public let backendFingerprint: String?
    /// Original capture/decoded rate when known. File import does not currently
    /// retain its encoded source rate after normalization, so it remains nil.
    public let sourceSampleRateHz: Double?
    /// Normalized PCM rate submitted to inference (currently 16 kHz).
    public let processingSampleRateHz: Double?
    public let audioFrames16k: Int?
    public let audioDurationSeconds: Double?
    public let firstSampleDelaySeconds: Double?
    public let recordingDurationSeconds: Double?
    public let stopDrainSeconds: Double?
    public let captureToResultSeconds: Double?
    public let recognizedWordCount: Int?
    public let wordsPerMinute: Double?
    public let modelWarm: Bool?
    public let modelLoadSeconds: Double?
    public let audioPreparationSeconds: Double?
    public let decodeSeconds: Double?
    /// Admission through the terminal event. Cancellation ends at its request,
    /// before resource drain; successful and failed work end when they return.
    public let endToEndSeconds: Double?
    /// Process delta through the terminal event, when both snapshots were available.
    /// Cancellation snapshots exclude subsequent resource drain.
    public let processCPUUserSeconds: Double?
    public let processCPUSystemSeconds: Double?
    /// Cumulative process high-water mark at the terminal event, not a session peak.
    /// Cancellation samples at the request, before resource drain.
    public let processPeakRSSBytesAtEvent: Int64?
    public let reviewAction: ReviewAction?
    public let actionSucceeded: Bool?
    public let rawWordCount: Int?
    public let editedWordCount: Int?
    /// Number of distinct text revisions observed after recognition, not word edits.
    public let editorRevisionCount: Int?
    public let failureCode: String?

    public init(eventID: UUID = UUID(), sessionID: UUID, timestamp: Date = Date(), kind: Kind,
                source: Source, requestedLanguage: String? = nil, detectedLanguageID: Int? = nil,
                modelFileName: String? = nil, modelSHA256: String? = nil,
                backendFingerprint: String? = nil, sourceSampleRateHz: Double? = nil,
                processingSampleRateHz: Double? = nil,
                audioFrames16k: Int? = nil, audioDurationSeconds: Double? = nil,
                firstSampleDelaySeconds: Double? = nil, recordingDurationSeconds: Double? = nil,
                stopDrainSeconds: Double? = nil, captureToResultSeconds: Double? = nil,
                recognizedWordCount: Int? = nil, wordsPerMinute: Double? = nil,
                modelWarm: Bool? = nil, modelLoadSeconds: Double? = nil,
                audioPreparationSeconds: Double? = nil, decodeSeconds: Double? = nil,
                endToEndSeconds: Double? = nil, processCPUUserSeconds: Double? = nil,
                processCPUSystemSeconds: Double? = nil, processPeakRSSBytesAtEvent: Int64? = nil,
                reviewAction: ReviewAction? = nil, actionSucceeded: Bool? = nil,
                rawWordCount: Int? = nil, editedWordCount: Int? = nil,
                editorRevisionCount: Int? = nil, failureCode: String? = nil) {
        self.schemaVersion = Self.currentSchemaVersion; self.eventID = eventID
        self.sessionID = sessionID; self.timestamp = timestamp; self.kind = kind; self.source = source
        self.requestedLanguage = requestedLanguage; self.detectedLanguageID = detectedLanguageID
        self.modelFileName = modelFileName; self.modelSHA256 = modelSHA256
        self.backendFingerprint = backendFingerprint
        self.sourceSampleRateHz = sourceSampleRateHz; self.processingSampleRateHz = processingSampleRateHz
        self.audioFrames16k = audioFrames16k; self.audioDurationSeconds = audioDurationSeconds
        self.firstSampleDelaySeconds = firstSampleDelaySeconds
        self.recordingDurationSeconds = recordingDurationSeconds
        self.stopDrainSeconds = stopDrainSeconds; self.captureToResultSeconds = captureToResultSeconds
        self.recognizedWordCount = recognizedWordCount; self.wordsPerMinute = wordsPerMinute
        self.modelWarm = modelWarm; self.modelLoadSeconds = modelLoadSeconds
        self.audioPreparationSeconds = audioPreparationSeconds; self.decodeSeconds = decodeSeconds
        self.endToEndSeconds = endToEndSeconds; self.processCPUUserSeconds = processCPUUserSeconds
        self.processCPUSystemSeconds = processCPUSystemSeconds
        self.processPeakRSSBytesAtEvent = processPeakRSSBytesAtEvent
        self.reviewAction = reviewAction; self.actionSucceeded = actionSucceeded
        self.rawWordCount = rawWordCount; self.editedWordCount = editedWordCount
        self.editorRevisionCount = editorRevisionCount; self.failureCode = failureCode
    }

    public static func wordCount(_ text: String) -> Int {
        // Match split-on-Character-whitespace semantics without retaining a
        // collection of Substrings for a large but valid transcript.
        var words = 0
        var tokenHasLetterOrNumber = false
        for character in text {
            if character.isWhitespace {
                if tokenHasLetterOrNumber { words += 1 }
                tokenHasLetterOrNumber = false
            } else if !tokenHasLetterOrNumber && (character.isLetter || character.isNumber) {
                tokenHasLetterOrNumber = true
            }
        }
        if tokenHasLetterOrNumber { words += 1 }
        return words
    }

    public static func wordsPerMinute(words: Int, audioSeconds: Double?) -> Double? {
        guard words >= 0, let seconds = audioSeconds, seconds.isFinite, seconds > 0 else { return nil }
        return Double(words) * 60 / seconds
    }
}

public struct LocalProcessUsageSnapshot: Sendable, Equatable {
    public let userCPUSeconds: Double
    public let systemCPUSeconds: Double
    public let peakRSSBytes: Int64

    public static func capture() -> Self? {
        var value = rusage()
        guard getrusage(RUSAGE_SELF, &value) == 0 else { return nil }
        let user = Double(value.ru_utime.tv_sec) + Double(value.ru_utime.tv_usec) / 1_000_000
        let system = Double(value.ru_stime.tv_sec) + Double(value.ru_stime.tv_usec) / 1_000_000
        return Self(userCPUSeconds: user, systemCPUSeconds: system, peakRSSBytes: Int64(value.ru_maxrss))
    }

    public init(userCPUSeconds: Double, systemCPUSeconds: Double, peakRSSBytes: Int64) {
        self.userCPUSeconds = userCPUSeconds; self.systemCPUSeconds = systemCPUSeconds
        self.peakRSSBytes = peakRSSBytes
    }
}

/// Append-only, segmented JSONL store. Each app launch writes to a new 0600
/// file, so a crash-truncated tail is preserved and never appended over.
/// An exclusive directory lock serializes the global capacity check and append.
/// Capacity exhaustion stops collection; historical records are never pruned.
public final class LocalMetricsJournal: @unchecked Sendable {
    public struct Limits: Sendable {
        public var totalBytes: Int
        public var fileCount: Int
        public var recordBytes: Int
        public init(totalBytes: Int = 10 * 1024 * 1024, fileCount: Int = 2_000,
                    recordBytes: Int = 16 * 1024) {
            self.totalBytes = totalBytes; self.fileCount = fileCount; self.recordBytes = recordBytes
        }
    }

    private let directoryURL: URL
    private let limits: Limits
    private let afterValidatingOldSegment: @Sendable (URL) -> Void
    private let queue = DispatchQueue(label: "org.clavune.local-metrics", qos: .utility)
    private let launchID = UUID()
    // Accessed only on queue.
    private var initialized = false
    private var disabled = false
    private var closed = false
    private var fd: Int32 = -1
    private var writerLockFD: Int32 = -1
    private var totalBytes = 0
    private var fileCount = 0
    private var eventIDs = Set<UUID>()
    private var terminalSessions = Set<UUID>()

    public init(directoryURL: URL, limits: Limits = Limits()) {
        self.directoryURL = directoryURL; self.limits = limits
        self.afterValidatingOldSegment = { _ in }
    }

    /// Synthetic race seam only. Production never mutates a prior segment.
    init(directoryURL: URL, limits: Limits = Limits(),
         afterValidatingOldSegment: @escaping @Sendable (URL) -> Void) {
        self.directoryURL = directoryURL; self.limits = limits
        self.afterValidatingOldSegment = afterValidatingOldSegment
    }

    public static func applicationDefault() -> LocalMetricsJournal? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                     in: .userDomainMask).first else { return nil }
        return LocalMetricsJournal(directoryURL: support.appendingPathComponent("Clavune/Metrics", isDirectory: true))
    }

    /// Enqueue never blocks the caller. The queue performs directory/file I/O
    /// and fsync; the real-time audio callback must never call this method.
    public func record(_ event: LocalMetricsEvent) {
        queue.async { [weak self] in self?.appendSynchronously(event) }
    }

    /// Waits for all earlier records and syncs the current journal (used at Quit
    /// and in tests). It does not change app behavior if metrics storage failed.
    public func synchronize() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { continuation.resume(returning: false); return }
                let ok = !self.disabled && (!self.initialized || (self.fd >= 0 && fsync(self.fd) == 0))
                continuation.resume(returning: ok)
            }
        }
    }

    /// Close this writer and release its process-wide quota lock. No records can
    /// be accepted afterward. Useful for orderly shutdown and deterministic tests.
    public func close() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { continuation.resume(returning: false); return }
                let result = !self.disabled && !self.closed &&
                    (!self.initialized || (self.fd >= 0 && fsync(self.fd) == 0))
                if self.fd >= 0 { Darwin.close(self.fd); self.fd = -1 }
                self.releaseWriterLock()
                self.closed = true; self.disabled = true
                continuation.resume(returning: result)
            }
        }
    }

    deinit {
        if fd >= 0 { Darwin.close(fd) }
        if writerLockFD >= 0 { Darwin.close(writerLockFD) }
    }

    private func appendSynchronously(_ event: LocalMetricsEvent) {
        guard !disabled, !closed, event.schemaVersion == LocalMetricsEvent.currentSchemaVersion,
              Self.isValid(event) else { return }
        guard prepareIfNeeded() else { disabled = true; return }
        guard !eventIDs.contains(event.eventID) else { return }
        if Self.isTerminal(event.kind), terminalSessions.contains(event.sessionID) { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            var bytes = try encoder.encode(event); bytes.append(0x0A)
            guard bytes.count <= limits.recordBytes, bytes.count <= limits.totalBytes,
                  totalBytes <= limits.totalBytes - bytes.count,
                  writeAll(bytes), fsync(fd) == 0 else { disabled = true; return }
            totalBytes += bytes.count; eventIDs.insert(event.eventID)
            if Self.isTerminal(event.kind) { terminalSessions.insert(event.sessionID) }
        } catch { disabled = true }
    }

    private func prepareIfNeeded() -> Bool {
        if initialized { return fd >= 0 }
        initialized = true
        guard limits.totalBytes > 0, limits.fileCount > 0, limits.recordBytes > 0 else { return false }
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directoryURL, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            let directoryFD = Darwin.open(directoryURL.path,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directoryFD >= 0 else { return false }
            defer { Darwin.close(directoryFD) }
            var directoryInfo = stat()
            guard fstat(directoryFD, &directoryInfo) == 0,
                  (directoryInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
                  (directoryInfo.st_mode & 0o7777) == 0o700,
                  directoryInfo.st_uid == geteuid(),
                  LocalMetricsACL.isAbsent(on: directoryFD) else { return false }
            guard acquireWriterLock() else { return false }
            var prepared = false
            defer {
                if !prepared {
                    if fd >= 0 { Darwin.close(fd); fd = -1 }
                    releaseWriterLock()
                }
            }
            let files = try manager.contentsOfDirectory(at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                options: [.skipsHiddenFiles])
                .filter { $0.lastPathComponent.hasPrefix("events-") && $0.pathExtension == "jsonl" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard files.count < limits.fileCount else { return false }
            fileCount = files.count
            var incompleteFiles = Set<URL>()
            var openSessions: [UUID: (event: LocalMetricsEvent, file: URL)] = [:]
            let decoder = JSONDecoder()
            for url in files {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      let size = values.fileSize, size >= 0,
                      size <= limits.totalBytes - totalBytes else { return false }
                let oldFD = url.lastPathComponent.withCString {
                    Darwin.openat(directoryFD, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                }
                guard oldFD >= 0 else { return false }
                let data = readValidatedOldSegment(oldFD, url: url, directoryFD: directoryFD,
                    listedSize: size)
                Darwin.close(oldFD)
                guard let data else { return false }
                totalBytes += data.count
                for rawLine in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
                    guard rawLine.count <= limits.recordBytes,
                          let event = try? decoder.decode(LocalMetricsEvent.self, from: Data(rawLine)),
                          event.schemaVersion == LocalMetricsEvent.currentSchemaVersion,
                          Self.isValid(event) else {
                        incompleteFiles.insert(url); continue
                    }
                    eventIDs.insert(event.eventID)
                    switch event.kind {
                    case .sessionStarted: openSessions[event.sessionID] = (event, url)
                    case .transcriptionCompleted, .sessionFailed, .sessionCancelled, .sessionInterrupted:
                        terminalSessions.insert(event.sessionID); openSessions.removeValue(forKey: event.sessionID)
                    case .reviewAction: break
                    }
                }
                if data.last != 0x0A { incompleteFiles.insert(url) }
            }
            guard totalBytes <= limits.totalBytes else { return false }
            let path = directoryURL.appendingPathComponent("events-\(launchID.uuidString).jsonl").path
            fd = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_APPEND, mode_t(0o600))
            guard fd >= 0 else { return false }
            var fileInfo = stat()
            guard fstat(fd, &fileInfo) == 0,
                  (fileInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                  (fileInfo.st_mode & 0o7777) == 0o600,
                  fileInfo.st_uid == geteuid(), fileInfo.st_nlink == 1,
                  LocalMetricsACL.isAbsent(on: fd) else { return false }
            fileCount += 1

            // Mark only recoverable starts from wholly valid prior journals.
            for (sessionID, pending) in openSessions where !incompleteFiles.contains(pending.file) {
                let start = pending.event
                let recovered = LocalMetricsEvent(sessionID: sessionID, kind: .sessionInterrupted,
                    source: start.source, requestedLanguage: start.requestedLanguage,
                    modelFileName: start.modelFileName, modelSHA256: start.modelSHA256,
                    backendFingerprint: start.backendFingerprint, failureCode: "process_interrupted")
                appendSynchronously(recovered)
                if disabled { return false }
            }
            prepared = true
            return true
        } catch { return false }
    }

    /// Read only the inode already opened below the verified directory. Never
    /// reopen the listed pathname after its ownership, mode and ACL check.
    private func readValidatedOldSegment(_ oldFD: Int32, url: URL,
                                         directoryFD: Int32, listedSize: Int) -> Data? {
        var before = stat()
        guard fstat(oldFD, &before) == 0,
              (before.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              (before.st_mode & 0o7777) == 0o600,
              before.st_uid == geteuid(), before.st_nlink == 1,
              before.st_size >= 0, before.st_size == off_t(listedSize),
              before.st_size <= off_t(limits.totalBytes),
              LocalMetricsACL.isAbsent(on: oldFD) else { return nil }
        afterValidatingOldSegment(url)
        let count = Int(before.st_size)
        var bytes = Data(count: count)
        if count > 0 {
            let complete = bytes.withUnsafeMutableBytes { raw -> Bool in
                guard let base = raw.baseAddress else { return false }
                var offset = 0
                while offset < count {
                    let amount = Darwin.pread(oldFD, base.advanced(by: offset),
                                              min(count - offset, 64 * 1024), off_t(offset))
                    if amount < 0 && errno == EINTR { continue }
                    guard amount > 0 else { return false }
                    offset += amount
                }
                return true
            }
            guard complete else { return nil }
        }
        var after = stat(), named = stat()
        guard fstat(oldFD, &after) == 0,
              (after.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              (after.st_mode & 0o7777) == 0o600,
              after.st_uid == geteuid(), after.st_nlink == 1,
              LocalMetricsACL.isAbsent(on: oldFD),
              after.st_dev == before.st_dev, after.st_ino == before.st_ino,
              after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec else { return nil }
        // Check the directory entry last so a replacement cannot silently
        // swap in a different inode while recovery consumes the checked bytes.
        let nameStillMatches = url.lastPathComponent.withCString {
            fstatat(directoryFD, $0, &named, AT_SYMLINK_NOFOLLOW) == 0
        }
        guard nameStillMatches,
              named.st_dev == before.st_dev, named.st_ino == before.st_ino,
              (named.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { return nil }
        return bytes
    }

    private func acquireWriterLock() -> Bool {
        let url = directoryURL.appendingPathComponent(".writer.lock", isDirectory: false)
        let candidate = Darwin.open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard candidate >= 0 else { return false }
        var info = stat()
        guard fstat(candidate, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              (info.st_mode & 0o7777) == 0o600,
              info.st_uid == geteuid(), info.st_nlink == 1,
              LocalMetricsACL.isAbsent(on: candidate),
              flock(candidate, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(candidate); return false
        }
        writerLockFD = candidate
        return true
    }

    private func releaseWriterLock() {
        guard writerLockFD >= 0 else { return }
        _ = flock(writerLockFD, LOCK_UN)
        Darwin.close(writerLockFD); writerLockFD = -1
    }

    private func writeAll(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return false }
            var offset = 0
            while offset < raw.count {
                let result = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if result <= 0 { return false }
                offset += result
            }
            return true
        }
    }

    /// Shared by append, recovery and offline statistics. A decoded JSON object
    /// must not become a counted session if the writer would have rejected it.
    static func isValid(_ event: LocalMetricsEvent) -> Bool {
        let finiteNonnegative = [event.sourceSampleRateHz, event.processingSampleRateHz,
            event.audioDurationSeconds,
            event.firstSampleDelaySeconds, event.recordingDurationSeconds, event.stopDrainSeconds,
            event.captureToResultSeconds, event.wordsPerMinute,
            event.modelLoadSeconds, event.audioPreparationSeconds, event.decodeSeconds,
            event.endToEndSeconds, event.processCPUUserSeconds, event.processCPUSystemSeconds]
            .compactMap { $0 }
        let languageIsKnown = event.requestedLanguage.map { LanguageMode(rawValue: $0) != nil } ?? true
        let modelNameIsSafe = event.modelFileName.map { value in
            !value.isEmpty && value.utf8.count <= 255 && !value.contains("/") && !value.contains("\\") &&
                value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
        } ?? true
        let hashIsValid = event.modelSHA256.map { value in
            value.utf8.count == 64 && value.utf8.allSatisfy {
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            }
        } ?? true
        let backendIsSafe = event.backendFingerprint.map { value in
            value.utf8.count == 64 && value.utf8.allSatisfy {
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            }
        } ?? true
        let failureCodeIsKnown = event.failureCode.map {
            DictationError(rawValue: $0) != nil || $0 == "process_interrupted"
        } ?? true
        let reviewFieldsArePresent = event.kind != .reviewAction ||
            (event.reviewAction != nil && event.actionSucceeded != nil)
        return event.timestamp.timeIntervalSince1970.isFinite &&
            finiteNonnegative.allSatisfy { $0.isFinite && $0 >= 0 } &&
            languageIsKnown && modelNameIsSafe && hashIsValid && backendIsSafe &&
            failureCodeIsKnown && reviewFieldsArePresent &&
            (event.audioFrames16k == nil || event.audioFrames16k! >= 0) &&
            (event.recognizedWordCount == nil || event.recognizedWordCount! >= 0) &&
            (event.rawWordCount == nil || event.rawWordCount! >= 0) &&
            (event.editedWordCount == nil || event.editedWordCount! >= 0) &&
            (event.editorRevisionCount == nil || event.editorRevisionCount! >= 0) &&
            (event.processPeakRSSBytesAtEvent == nil || event.processPeakRSSBytesAtEvent! >= 0)
    }

    private static func isTerminal(_ kind: LocalMetricsEvent.Kind) -> Bool {
        [.transcriptionCompleted, .sessionFailed, .sessionCancelled, .sessionInterrupted].contains(kind)
    }
}
