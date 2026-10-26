import Foundation

/// Pure, bounded aggregation of already-recorded content-free journal events.
/// This does not read the journal, run on the audio path, or prove complete usage history.
public enum LocalStatisticsSummaryBuilder {
    public enum Failure: Error, Equatable { case invalidPeriod, tooManyEvents, numericOverflow }
    public static let maximumInputEvents = 50_000

    public struct Period: Sendable, Equatable {
        public let start: Date
        public let endExclusive: Date
        public init(start: Date, endExclusive: Date) throws {
            guard start.timeIntervalSince1970.isFinite, endExclusive.timeIntervalSince1970.isFinite,
                  start < endExclusive else { throw Failure.invalidPeriod }
            self.start = start; self.endExclusive = endExclusive
        }
        fileprivate func contains(_ date: Date) -> Bool { start <= date && date < endExclusive }
    }

    /// Nil sum/mean means there were no usable observations, not a measured zero.
    public struct MeasuredDouble: Sendable, Equatable {
        public let observed: Int
        public let unknown: Int
        public let sum: Double?
        public let mean: Double?
    }

    public struct Words: Sendable, Equatable {
        public let observed: Int
        public let unknown: Int
        public let sum: Int?
    }

    public struct ReviewCounts: Sendable, Equatable {
        /// Distinct event IDs: repeated user actions are attempts, not new sessions.
        public let attempts: Int
        public let succeeded: Int
        /// Includes picker cancellations and genuine errors; neither is inferred as a failure.
        public let notSucceeded: Int
        /// Nil for transcript-file actions: idle document actions receive a new
        /// synthetic UUID per action, not a stable document/session identity.
        public let distinctSuccessfulSessions: Int?
    }

    public struct Reviews: Sendable, Equatable {
        public let copy: ReviewCounts
        public let save: ReviewCounts
        public let open: ReviewCounts
        public let discard: ReviewCounts
        public let cancel: ReviewCounts
    }

    public struct RequestedLanguageCounts: Sendable, Equatable {
        /// Counts only valid completed transcriptions, not document actions.
        public let auto: Int
        public let german: Int
        public let english: Int
        public let unknown: Int
        /// Raw IDs only. Do not label them as a language without the backend map.
        public let autoDetectedRawIDs: [Int: Int]
        public let autoDetectionUnknown: Int
    }

    public struct Source: Sendable, Equatable {
        public let kind: LocalMetricsEvent.Source
        /// Starts and terminal outcomes use their own event timestamps in the period.
        /// Cross-boundary sessions mean these columns need not sum to each other.
        public let started: Int
        public let completed: Int
        public let failed: Int
        public let cancelled: Int
        public let interrupted: Int
        /// A valid start in this period with no terminal before endExclusive.
        /// It is not silently called a failure or an inferred interruption.
        public let incompleteAtPeriodEnd: Int
        public let ambiguous: Int
        public let recognizedWordsOnCompleted: Words
        public let audioSecondsOnCompleted: MeasuredDouble
        /// Recorded words/minute of full audio, pauses included; not WER or speaking rate.
        /// `mean` is the arithmetic mean of observed per-session rates, not pooled
        /// total words divided by pooled audio time.
        public let audioWordRateOnCompleted: MeasuredDouble
        /// InferenceService decode call through result/language extraction; excludes queue wait/UI.
        /// This is not independently measured native decoder compute.
        public let decodeServiceSecondsOnCompleted: MeasuredDouble
        public let endToEndSecondsOnCompleted: MeasuredDouble
        /// Applicable to audio-file import only; do not pool with microphone capture.
        public let filePreparationSecondsOnCompleted: MeasuredDouble
        /// Applicable to microphone only; distinct from file preparation.
        public let captureToResultSecondsOnCompleted: MeasuredDouble
        public let requestedLanguageOnCompleted: RequestedLanguageCounts
        public let reviews: Reviews
    }

    public struct Report: Sendable, Equatable {
        public let period: Period
        public let suppliedEventCount: Int
        public let uniqueUsableEventCountBeforePeriodEnd: Int
        public let duplicateEventRecords: Int
        public let conflictingEventIDGroups: Int
        public let invalidTimestampEvents: Int
        public let unsupportedSchemaEvents: Int
        public let invalidRecordEvents: Int
        public let orphanTerminalSessions: Int
        public let orphanReviewEvents: Int
        /// True because journal writing may stop at quota/error and this pure layer
        /// has no proof that all app activity was ever retained.
        public let historicalCoverageUnknown: Bool
        public let microphone: Source
        public let audioFile: Source
        public let transcriptFile: Source
    }

    private struct DoubleAccumulator {
        var observed = 0, unknown = 0
        var sum = 0.0
        mutating func add(_ value: Double?) throws {
            guard let value, value.isFinite, value >= 0 else { unknown += 1; return }
            let next = sum + value
            guard next.isFinite else { throw Failure.numericOverflow }
            sum = next; observed += 1
        }
        var result: MeasuredDouble {
            MeasuredDouble(observed: observed, unknown: unknown,
                    sum: observed == 0 ? nil : sum,
                    mean: observed == 0 ? nil : sum / Double(observed))
        }
    }

    private struct WordsAccumulator {
        var observed = 0, unknown = 0, sum = 0
        mutating func add(_ value: Int?) throws {
            guard let value, value >= 0 else { unknown += 1; return }
            let (next, overflow) = sum.addingReportingOverflow(value)
            guard !overflow else { throw Failure.numericOverflow }
            sum = next; observed += 1
        }
        var result: Words { Words(observed: observed, unknown: unknown,
                                  sum: observed == 0 ? nil : sum) }
    }

    private struct ReviewAccumulator {
        var attempts = 0, succeeded = 0, notSucceeded = 0
        var successfulSessions = Set<UUID>()
        mutating func add(_ event: LocalMetricsEvent, stableSessionIdentity: Bool) {
            attempts += 1
            if event.actionSucceeded == true {
                succeeded += 1
                if stableSessionIdentity { successfulSessions.insert(event.sessionID) }
            } else { notSucceeded += 1 }
        }
        func result(stableSessionIdentity: Bool) -> ReviewCounts {
            ReviewCounts(attempts: attempts, succeeded: succeeded, notSucceeded: notSucceeded,
                         distinctSuccessfulSessions: stableSessionIdentity ? successfulSessions.count : nil)
        }
    }

    private struct SourceAccumulator {
        let kind: LocalMetricsEvent.Source
        var started = 0, completed = 0, failed = 0, cancelled = 0, interrupted = 0
        var incomplete = 0, ambiguous = 0
        var words = WordsAccumulator()
        var audio = DoubleAccumulator(), rate = DoubleAccumulator()
        var batch = DoubleAccumulator(), endToEnd = DoubleAccumulator()
        var filePreparation = DoubleAccumulator(), captureToResult = DoubleAccumulator()
        var requestedAuto = 0, requestedDE = 0, requestedEN = 0, requestedUnknown = 0
        var detectedIDs: [Int: Int] = [:]
        var detectionUnknown = 0
        var copy = ReviewAccumulator(), save = ReviewAccumulator(), open = ReviewAccumulator()
        var discard = ReviewAccumulator(), cancel = ReviewAccumulator()

        mutating func addCompleted(_ terminal: LocalMetricsEvent, start: LocalMetricsEvent) throws {
            completed += 1
            try words.add(terminal.recognizedWordCount)
            try audio.add(terminal.audioDurationSeconds)
            let validRate: Double?
            if let recorded = terminal.wordsPerMinute, recorded.isFinite, recorded >= 0,
               let count = terminal.recognizedWordCount, count >= 0,
               let duration = terminal.audioDurationSeconds, duration.isFinite, duration > 0 {
                let computed = Double(count) * 60 / duration
                validRate = computed.isFinite &&
                    abs(recorded - computed) <= max(1e-7, abs(computed) * 1e-8) ? recorded : nil
            } else { validRate = nil }
            try rate.add(validRate)
            try batch.add(terminal.decodeSeconds)
            try endToEnd.add(terminal.endToEndSeconds)
            if kind == .audioFile { try filePreparation.add(terminal.audioPreparationSeconds) }
            if kind == .microphone { try captureToResult.add(terminal.captureToResultSeconds) }
            switch terminal.requestedLanguage ?? start.requestedLanguage {
            case "auto":
                requestedAuto += 1
                if let id = terminal.detectedLanguageID, id >= 0 {
                    detectedIDs[id, default: 0] += 1
                } else { detectionUnknown += 1 }
            case "de": requestedDE += 1
            case "en": requestedEN += 1
            default: requestedUnknown += 1
            }
        }

        mutating func review(_ event: LocalMetricsEvent) {
            let stable = kind != .transcriptFile
            switch event.reviewAction {
            case .some(.copy): copy.add(event, stableSessionIdentity: stable)
            case .some(.save): save.add(event, stableSessionIdentity: stable)
            case .some(.open): open.add(event, stableSessionIdentity: stable)
            case .some(.discard): discard.add(event, stableSessionIdentity: stable)
            case .some(.cancel): cancel.add(event, stableSessionIdentity: stable)
            case nil: break
            }
        }

        var result: Source {
            Source(kind: kind, started: started, completed: completed, failed: failed,
                   cancelled: cancelled, interrupted: interrupted,
                   incompleteAtPeriodEnd: incomplete, ambiguous: ambiguous,
                   recognizedWordsOnCompleted: words.result,
                   audioSecondsOnCompleted: audio.result,
                   audioWordRateOnCompleted: rate.result,
                   decodeServiceSecondsOnCompleted: batch.result,
                   endToEndSecondsOnCompleted: endToEnd.result,
                   filePreparationSecondsOnCompleted: filePreparation.result,
                   captureToResultSecondsOnCompleted: captureToResult.result,
                   requestedLanguageOnCompleted: RequestedLanguageCounts(
                       auto: requestedAuto, german: requestedDE, english: requestedEN,
                       unknown: requestedUnknown, autoDetectedRawIDs: detectedIDs,
                       autoDetectionUnknown: detectionUnknown),
                   reviews: Reviews(copy: copy.result(stableSessionIdentity: kind != .transcriptFile),
                                    save: save.result(stableSessionIdentity: kind != .transcriptFile),
                                    open: open.result(stableSessionIdentity: kind != .transcriptFile),
                                    discard: discard.result(stableSessionIdentity: kind != .transcriptFile),
                                    cancel: cancel.result(stableSessionIdentity: kind != .transcriptFile)))
        }
    }

    private struct SessionEvents {
        var starts: [LocalMetricsEvent] = []
        var terminals: [LocalMetricsEvent] = []
    }

    private static func index(_ source: LocalMetricsEvent.Source) -> Int {
        switch source { case .microphone: return 0; case .audioFile: return 1; case .transcriptFile: return 2 }
    }
    private static func isTerminal(_ kind: LocalMetricsEvent.Kind) -> Bool {
        switch kind {
        case .transcriptionCompleted, .sessionFailed, .sessionCancelled, .sessionInterrupted: return true
        case .sessionStarted, .reviewAction: return false
        }
    }

    /// Invoke on a utility worker after an independently bounded, private read;
    /// do not synchronously parse journals or aggregate on SwiftUI's main actor.
    /// Supply all retained records BEFORE `period.endExclusive`, not just records
    /// inside the display period: an older start can own a terminal in the period,
    /// and an older completed terminal can own a later review action.
    public static func build(events: [LocalMetricsEvent], period: Period) throws -> Report {
        guard events.count <= maximumInputEvents else { throw Failure.tooManyEvents }
        var unique: [UUID: LocalMetricsEvent] = [:]
        var conflictingIDs = Set<UUID>()
        var poisonedSessionEvents: [UUID: [LocalMetricsEvent]] = [:]
        var duplicates = 0, invalidTimestamps = 0
        for event in events {
            guard event.timestamp.timeIntervalSince1970.isFinite else {
                invalidTimestamps += 1
                if event.kind != .reviewAction {
                    poisonedSessionEvents[event.sessionID, default: []].append(event)
                }
                continue
            }
            guard event.timestamp < period.endExclusive else { continue }
            if conflictingIDs.contains(event.eventID) {
                duplicates += 1
                if event.kind != .reviewAction {
                    poisonedSessionEvents[event.sessionID, default: []].append(event)
                }
                continue
            }
            if let prior = unique[event.eventID] {
                duplicates += 1
                if prior != event {
                    unique.removeValue(forKey: event.eventID); conflictingIDs.insert(event.eventID)
                    // A conflicting terminal/start is evidence of an ambiguous
                    // session, not evidence that its start is still incomplete.
                    for conflicting in [prior, event] where conflicting.kind != .reviewAction {
                        poisonedSessionEvents[conflicting.sessionID, default: []].append(conflicting)
                    }
                }
            } else { unique[event.eventID] = event }
        }
        let ordered = unique.values.sorted {
            $0.timestamp == $1.timestamp ? $0.eventID.uuidString < $1.eventID.uuidString : $0.timestamp < $1.timestamp
        }
        var buckets = [SourceAccumulator(kind: .microphone), SourceAccumulator(kind: .audioFile),
                       SourceAccumulator(kind: .transcriptFile)]
        var sessions: [UUID: SessionEvents] = [:]
        var reviews: [LocalMetricsEvent] = []
        var unsupported = 0, invalid = 0, orphanTerminals = 0, orphanReviews = 0
        var usable = 0
        for event in ordered {
            guard event.schemaVersion == LocalMetricsEvent.currentSchemaVersion else {
                unsupported += 1
                if event.kind != .reviewAction {
                    poisonedSessionEvents[event.sessionID, default: []].append(event)
                }
                continue
            }
            guard LocalMetricsJournal.isValid(event) else {
                invalid += 1
                if event.kind != .reviewAction {
                    poisonedSessionEvents[event.sessionID, default: []].append(event)
                }
                continue
            }
            switch event.kind {
            case .sessionStarted:
                guard event.source != .transcriptFile else {
                    invalid += 1; poisonedSessionEvents[event.sessionID, default: []].append(event); continue
                }
                sessions[event.sessionID, default: SessionEvents()].starts.append(event); usable += 1
            case .transcriptionCompleted, .sessionFailed, .sessionCancelled, .sessionInterrupted:
                guard event.source != .transcriptFile else {
                    invalid += 1; poisonedSessionEvents[event.sessionID, default: []].append(event); continue
                }
                sessions[event.sessionID, default: SessionEvents()].terminals.append(event); usable += 1
            case .reviewAction:
                guard event.reviewAction != nil, event.actionSucceeded != nil else { invalid += 1; continue }
                reviews.append(event); usable += 1
            }
        }
        var completedSessions: [UUID: LocalMetricsEvent] = [:]
        // A stable session order also makes floating-point reductions reproducible.
        let allSessionIDs = Set(sessions.keys).union(poisonedSessionEvents.keys)
        let orderedSessionIDs = allSessionIDs.map { ($0.uuidString, $0) }
            .sorted { $0.0 < $1.0 }.map { $0.1 }
        for sessionID in orderedSessionIDs {
            let state = sessions[sessionID] ?? SessionEvents()
            let first = state.starts.first
            let final = state.terminals.first
            // A valid observed start remains a start even when its outcome is
            // ambiguous; never relabel it as an unfinished live session.
            if state.starts.count == 1, let first, period.contains(first.timestamp) {
                buckets[index(first.source)].started += 1
            }
            if let poisoned = poisonedSessionEvents[sessionID] {
                let related = state.starts + state.terminals + poisoned
                if related.contains(where: { period.contains($0.timestamp) }),
                   let source = first?.source ?? final?.source ?? poisoned.first?.source {
                    buckets[index(source)].ambiguous += 1
                }
                continue
            }
            if state.starts.isEmpty {
                if state.terminals.contains(where: { period.contains($0.timestamp) }) { orphanTerminals += 1 }
                continue
            }
            if state.terminals.isEmpty {
                if state.starts.count == 1, let first, period.contains(first.timestamp) {
                    buckets[index(first.source)].incomplete += 1
                } else if state.starts.count > 1,
                          state.starts.contains(where: { period.contains($0.timestamp) }), let first {
                    buckets[index(first.source)].ambiguous += 1
                }
                continue
            }
            guard let first, let final else { continue }
            // An invalid association makes any in-period event for this session
            // uncertain, even when the malformed terminal lies before the period.
            let relatedInPeriod = state.starts.contains { period.contains($0.timestamp) } ||
                state.terminals.contains { period.contains($0.timestamp) }
            guard state.starts.count == 1, state.terminals.count == 1,
                  first.timestamp <= final.timestamp, first.source == final.source,
                  first.requestedLanguage == nil || final.requestedLanguage == nil ||
                    first.requestedLanguage == final.requestedLanguage else {
                if relatedInPeriod { buckets[index(first.source)].ambiguous += 1 }
                continue
            }
            if final.kind == .transcriptionCompleted { completedSessions[sessionID] = final }
            guard period.contains(final.timestamp) else { continue }
            let bucket = index(final.source)
            switch final.kind {
            case .transcriptionCompleted: try buckets[bucket].addCompleted(final, start: first)
            case .sessionFailed: buckets[bucket].failed += 1
            case .sessionCancelled: buckets[bucket].cancelled += 1
            case .sessionInterrupted: buckets[bucket].interrupted += 1
            case .sessionStarted, .reviewAction: break
            }
        }
        for event in reviews where period.contains(event.timestamp) {
            if event.source != .transcriptFile {
                guard let completed = completedSessions[event.sessionID],
                      completed.source == event.source, completed.timestamp <= event.timestamp else {
                    orphanReviews += 1; continue
                }
            }
            buckets[index(event.source)].review(event)
        }
        return Report(period: period, suppliedEventCount: events.count,
                      uniqueUsableEventCountBeforePeriodEnd: usable,
                      duplicateEventRecords: duplicates,
                      conflictingEventIDGroups: conflictingIDs.count,
                      invalidTimestampEvents: invalidTimestamps,
                      unsupportedSchemaEvents: unsupported,
                      invalidRecordEvents: invalid,
                      orphanTerminalSessions: orphanTerminals,
                      orphanReviewEvents: orphanReviews,
                      historicalCoverageUnknown: true,
                      microphone: buckets[0].result, audioFile: buckets[1].result,
                      transcriptFile: buckets[2].result)
    }
}
