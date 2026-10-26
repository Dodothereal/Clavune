import Darwin
import Foundation

/// Read-only, bounded view of visible local metrics bytes. This is a *prefix*
/// cut, not proof that every enqueued event was durably synced or that lifetime
/// activity was recorded.
/// Invoke from a utility worker, never synchronously from the SwiftUI main actor.
/// Raw events and unknown JSON fields never leave ClavuneCore through this API.
public enum LocalMetricsSnapshotReader {
    public enum State: String, Sendable, Equatable {
        /// No current retained records, including a missing as-yet-unused
        /// metrics directory. It does not mean no lifetime app use.
        case validEmpty
        /// Every captured segment was safely read and structurally valid.
        case complete
        /// Some captured data was malformed, unsafe, torn, or changed during read.
        /// `summary` contains only countable records and is not complete history.
        case partial
        /// No trustworthy summary can be produced within the safety bounds.
        case unavailable
    }

    public enum UnavailableReason: String, Sendable, Equatable {
        case invalidLimits, directoryUnavailable, directoryUnsafe
        case enumerationFailed, capacityExceeded, aggregationRejected, cancelled
    }

    public struct Diagnostics: Sendable, Equatable {
        public let state: State
        public let unavailableReason: UnavailableReason?
        public let segmentCount: Int
        public let acceptedRecordCount: Int
        public let invalidRecordCount: Int
        public let tornTailCount: Int
        public let unsafeOrUnreadableSegmentCount: Int
        public let concurrentChangeDetected: Bool
        /// Quota exhaustion, writer failure, disabled journal, and older history
        /// cannot be disproved by a disk snapshot, even when state is complete.
        public let historicalCoverageUnknown: Bool
    }

    public struct Result: Sendable {
        /// Nil only for `unavailable`; do not treat nil as an empty history.
        public let summary: LocalStatisticsSummaryBuilder.Report?
        public let diagnostics: Diagnostics
    }

    private struct Counts {
        var segmentCount = 0
        var acceptedRecordCount = 0
        var invalidRecordCount = 0
        var tornTailCount = 0
        var unsafeOrUnreadableSegmentCount = 0
        var concurrentChangeDetected = false
        var hasUntrustedSessionAssociations = false
        var isPartial: Bool {
            invalidRecordCount > 0 || tornTailCount > 0 ||
                unsafeOrUnreadableSegmentCount > 0 || concurrentChangeDetected ||
                hasUntrustedSessionAssociations
        }
        func diagnostics(_ state: State, reason: UnavailableReason? = nil) -> Diagnostics {
            Diagnostics(state: state, unavailableReason: reason,
                segmentCount: segmentCount, acceptedRecordCount: acceptedRecordCount,
                invalidRecordCount: invalidRecordCount, tornTailCount: tornTailCount,
                unsafeOrUnreadableSegmentCount: unsafeOrUnreadableSegmentCount,
                concurrentChangeDetected: concurrentChangeDetected,
                historicalCoverageUnknown: true)
        }
    }

    private enum DirectoryOpen {
        case opened(Int32), missingNearLeaf, unsafe
    }

    private enum ParseResult { case complete, capacityExceeded, cancelled }

    private static let maximumTotalBytes = 10 * 1024 * 1024
    private static let maximumSegments = 2_000
    private static let maximumRecordBytes = 16 * 1024
    private static let maximumOtherDirectoryEntries = 32

    // Schema v1 allowlist. Reject unknown keys before typed decoding so a
    // hand-edited record containing text/path payloads is never counted cleanly.
    // A future schema must deliberately update this list and the decoder.
    private static let eventKeys: Set<String> = [
        "schemaVersion", "eventID", "sessionID", "timestamp", "kind", "source",
        "requestedLanguage", "detectedLanguageID", "modelFileName", "modelSHA256",
        "backendFingerprint", "sourceSampleRateHz", "processingSampleRateHz",
        "audioFrames16k", "audioDurationSeconds", "firstSampleDelaySeconds",
        "recordingDurationSeconds", "stopDrainSeconds", "captureToResultSeconds",
        "recognizedWordCount", "wordsPerMinute", "modelWarm", "modelLoadSeconds",
        "audioPreparationSeconds", "decodeSeconds", "endToEndSeconds",
        "processCPUUserSeconds", "processCPUSystemSeconds", "processPeakRSSBytesAtEvent",
        "reviewAction", "actionSucceeded", "rawWordCount", "editedWordCount",
        "editorRevisionCount", "failureCode"
    ]

    /// This synchronous method performs up to 10 MiB of disk I/O and decoding.
    /// The caller must run it off MainActor (for example, Task.detached .utility).
    /// It does not call `synchronize()`; an event still queued by the writer may
    /// be absent. The fixed-size per-file cuts exclude later appends without
    /// duplicating records. Any partial line at a cut is ignored and disclosed.
    public static func readSummary(directoryURL: URL,
        period: LocalStatisticsSummaryBuilder.Period,
        limits: LocalMetricsJournal.Limits = .init()) -> Result {
        readSummary(directoryURL: directoryURL, period: period, limits: limits,
            shouldCancel: { Task<Never, Never>.isCancelled },
            afterCapturingSegmentSize: {})
    }

    /// Test seam for a deterministic cancellation point; not a second App API.
    static func readSummary(directoryURL: URL,
        period: LocalStatisticsSummaryBuilder.Period,
        limits: LocalMetricsJournal.Limits,
        shouldCancel: () -> Bool,
        afterCapturingSegmentSize: () -> Void = {}) -> Result {
        var counts = Counts()
        func unavailable(_ reason: UnavailableReason) -> Result {
            Result(summary: nil, diagnostics: counts.diagnostics(.unavailable, reason: reason))
        }
        if shouldCancel() { return unavailable(.cancelled) }
        guard limits.totalBytes > 0, limits.totalBytes <= maximumTotalBytes,
              limits.fileCount > 0, limits.fileCount <= maximumSegments,
              limits.recordBytes > 0, limits.recordBytes <= maximumRecordBytes else {
            return unavailable(.invalidLimits)
        }
        guard directoryURL.isFileURL else {
            return unavailable(.directoryUnavailable)
        }
        let directoryFD: Int32
        switch openDirectoryWithoutSymlinks(directoryURL.path) {
        case .opened(let fd): directoryFD = fd
        case .missingNearLeaf:
            // A fresh profile may not yet have created Clavune/Metrics. This
            // means no *currently retained* records, not zero lifetime usage.
            if shouldCancel() { return unavailable(.cancelled) }
            guard let empty = try? LocalStatisticsSummaryBuilder.build(events: [], period: period) else {
                return unavailable(.aggregationRejected)
            }
            return Result(summary: empty, diagnostics: counts.diagnostics(.validEmpty))
        case .unsafe:
            return unavailable(.directoryUnavailable)
        }
        defer { Darwin.close(directoryFD) }
        var directoryBefore = stat()
        guard fstat(directoryFD, &directoryBefore) == 0,
              isPrivateDirectory(directoryBefore),
              LocalMetricsACL.isAbsent(on: directoryFD) else {
            return unavailable(.directoryUnsafe)
        }

        let duplicatedFD = Darwin.dup(directoryFD)
        guard duplicatedFD >= 0 else { return unavailable(.enumerationFailed) }
        guard let stream = fdopendir(duplicatedFD) else {
            Darwin.close(duplicatedFD)
            return unavailable(.enumerationFailed)
        }
        var names: [String] = []
        var entries = 0
        var listingFailed = false
        var listingExceededCapacity = false
        while true {
            if shouldCancel() { _ = closedir(stream); return unavailable(.cancelled) }
            errno = 0
            guard let entry = readdir(stream) else {
                listingFailed = errno != 0
                break
            }
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw -> String? in
                guard length > 0, length <= raw.count else { return nil }
                return String(bytes: raw.prefix(length), encoding: .utf8)
            }
            guard let name else { listingFailed = true; break }
            if name == "." || name == ".." { continue }
            entries += 1
            if entries > limits.fileCount + maximumOtherDirectoryEntries {
                listingExceededCapacity = true; break
            }
            if name.hasPrefix("events-") && name.hasSuffix(".jsonl") {
                names.append(name)
                if names.count > limits.fileCount { listingExceededCapacity = true; break }
            }
        }
        _ = closedir(stream)
        if listingExceededCapacity { return unavailable(.capacityExceeded) }
        guard !listingFailed else { return unavailable(.enumerationFailed) }
        names.sort()
        counts.segmentCount = names.count

        var events: [LocalMetricsEvent] = []
        var totalBytes = 0
        let decoder = JSONDecoder()
        for name in names {
            if shouldCancel() { return unavailable(.cancelled) }
            let fileFD = name.withCString {
                Darwin.openat(directoryFD, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            }
            guard fileFD >= 0 else {
                counts.unsafeOrUnreadableSegmentCount += 1; continue
            }
            defer { Darwin.close(fileFD) }
            var before = stat()
            guard fstat(fileFD, &before) == 0, isPrivateRegularFile(before),
                  LocalMetricsACL.isAbsent(on: fileFD) else {
                counts.unsafeOrUnreadableSegmentCount += 1; continue
            }
            guard before.st_size >= 0,
                  before.st_size <= off_t(limits.totalBytes - totalBytes) else {
                return unavailable(.capacityExceeded)
            }
            let byteCount = Int(before.st_size)
            totalBytes += byteCount
            // Internal no-op in production; synthetic tests can append here to
            // verify the fixed-size cut rather than relying on a timing race.
            afterCapturingSegmentSize()
            if shouldCancel() { return unavailable(.cancelled) }
            guard let bytes = readExactly(fileFD, count: byteCount, shouldCancel: shouldCancel) else {
                if shouldCancel() { return unavailable(.cancelled) }
                counts.unsafeOrUnreadableSegmentCount += 1; continue
            }
            var after = stat()
            guard fstat(fileFD, &after) == 0, isPrivateRegularFile(after),
                  LocalMetricsACL.isAbsent(on: fileFD),
                  after.st_dev == before.st_dev, after.st_ino == before.st_ino,
                  after.st_size >= before.st_size else {
                counts.unsafeOrUnreadableSegmentCount += 1; continue
            }
            let metadataChanged = after.st_mtimespec.tv_sec != before.st_mtimespec.tv_sec ||
                after.st_mtimespec.tv_nsec != before.st_mtimespec.tv_nsec ||
                after.st_ctimespec.tv_sec != before.st_ctimespec.tv_sec ||
                after.st_ctimespec.tv_nsec != before.st_ctimespec.tv_nsec
            if metadataChanged && after.st_size == before.st_size {
                counts.unsafeOrUnreadableSegmentCount += 1; continue
            }
            if after.st_size > before.st_size { counts.concurrentChangeDetected = true }
            switch parseCompleteLines(bytes, decoder: decoder, limit: limits.recordBytes,
                                      events: &events, counts: &counts,
                                      shouldCancel: shouldCancel) {
            case .complete: break
            case .capacityExceeded: return unavailable(.capacityExceeded)
            case .cancelled: return unavailable(.cancelled)
            }
        }
        var directoryAfter = stat()
        guard fstat(directoryFD, &directoryAfter) == 0,
              isPrivateDirectory(directoryAfter),
              LocalMetricsACL.isAbsent(on: directoryFD),
              directoryAfter.st_dev == directoryBefore.st_dev,
              directoryAfter.st_ino == directoryBefore.st_ino else {
            return unavailable(.directoryUnsafe)
        }
        if directoryAfter.st_mtimespec.tv_sec != directoryBefore.st_mtimespec.tv_sec ||
           directoryAfter.st_mtimespec.tv_nsec != directoryBefore.st_mtimespec.tv_nsec ||
           directoryAfter.st_ctimespec.tv_sec != directoryBefore.st_ctimespec.tv_sec ||
           directoryAfter.st_ctimespec.tv_nsec != directoryBefore.st_ctimespec.tv_nsec {
            counts.concurrentChangeDetected = true
        }
        if shouldCancel() { return unavailable(.cancelled) }
        guard let summary = try? LocalStatisticsSummaryBuilder.build(events: events, period: period) else {
            return unavailable(.aggregationRejected)
        }
        if shouldCancel() { return unavailable(.cancelled) }
        if summary.duplicateEventRecords > 0 || summary.conflictingEventIDGroups > 0 ||
           summary.invalidTimestampEvents > 0 || summary.unsupportedSchemaEvents > 0 ||
           summary.invalidRecordEvents > 0 ||
           summary.orphanTerminalSessions > 0 || summary.orphanReviewEvents > 0 ||
           summary.microphone.ambiguous > 0 || summary.audioFile.ambiguous > 0 {
            counts.hasUntrustedSessionAssociations = true
        }
        let state: State = counts.isPartial ? .partial :
            (counts.acceptedRecordCount == 0 ? .validEmpty : .complete)
        return Result(summary: summary, diagnostics: counts.diagnostics(state))
    }

    private static func isPrivateDirectory(_ value: stat) -> Bool {
        (value.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) &&
            (value.st_mode & 0o7777) == 0o700 && value.st_uid == geteuid()
    }

    /// Open every component from `/` through a retained directory descriptor.
    /// Checking only the final component would follow an attacker-controlled
    /// intermediate symlink before `O_NOFOLLOW` could protect Metrics itself.
    private static func openDirectoryWithoutSymlinks(_ path: String) -> DirectoryOpen {
        guard path.hasPrefix("/"), path.utf8.count <= 4_096,
              !path.contains("\0") else { return .unsafe }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count <= 64,
              !components.contains(where: { $0 == "." || $0 == ".." }) else { return .unsafe }
        var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { return .unsafe }
        for (index, component) in components.enumerated() {
            let next = String(component).withCString {
                Darwin.openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            if next < 0 {
                let missing = errno == ENOENT
                Darwin.close(current)
                // Metrics itself or its Clavune owner folder can be absent on
                // first use. A missing home/Library ancestor is not proven empty.
                return missing && components.count - index <= 2 ? .missingNearLeaf : .unsafe
            }
            Darwin.close(current)
            current = next
        }
        return .opened(current)
    }

    private static func isPrivateRegularFile(_ value: stat) -> Bool {
        (value.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) &&
            (value.st_mode & 0o7777) == 0o600 && value.st_uid == geteuid() &&
            value.st_nlink == 1
    }

    private static func readExactly(_ fd: Int32, count: Int,
                                    shouldCancel: () -> Bool) -> Data? {
        var bytes = Data(count: count)
        if count == 0 { return bytes }
        let complete = bytes.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress else { return false }
            var offset = 0
            while offset < count {
                if shouldCancel() { return false }
                let amount = Darwin.pread(fd, base.advanced(by: offset),
                                          min(count - offset, 64 * 1024), off_t(offset))
                if amount < 0 && errno == EINTR { continue }
                guard amount > 0 else { return false }
                offset += amount
            }
            return true
        }
        return complete ? bytes : nil
    }

    private static func parseCompleteLines(_ bytes: Data, decoder: JSONDecoder,
        limit: Int, events: inout [LocalMetricsEvent], counts: inout Counts,
        shouldCancel: () -> Bool) -> ParseResult {
        var beginning = 0
        for offset in bytes.indices {
            if (offset & 0xFFFF) == 0 && shouldCancel() { return .cancelled }
            if bytes[offset] != 0x0A { continue }
            let lineBytes = offset - beginning + 1
            defer { beginning = offset + 1 }
            guard lineBytes > 1, lineBytes <= limit else {
                counts.invalidRecordCount += 1; continue
            }
            let line = Data(bytes[beginning..<offset])
            guard let object = try? JSONSerialization.jsonObject(with: line),
                  let dictionary = object as? [String: Any],
                  dictionary.keys.allSatisfy({ eventKeys.contains($0) }),
                  let event = try? decoder.decode(LocalMetricsEvent.self, from: line) else {
                counts.invalidRecordCount += 1; continue
            }
            // Pass semantically invalid *typed* events only to the private pure
            // builder, which marks their session ambiguous rather than calling
            // a valid start an unfinished session. None are returned to App.
            guard events.count < LocalStatisticsSummaryBuilder.maximumInputEvents else {
                return .capacityExceeded
            }
            events.append(event)
            if event.schemaVersion == LocalMetricsEvent.currentSchemaVersion &&
               LocalMetricsJournal.isValid(event) {
                counts.acceptedRecordCount += 1
            } else {
                counts.invalidRecordCount += 1
            }
        }
        if beginning < bytes.count { counts.tornTailCount += 1 }
        return .complete
    }
}
