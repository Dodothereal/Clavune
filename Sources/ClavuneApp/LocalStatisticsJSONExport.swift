import ClavuneCore
import Foundation

/// Fixed, reviewed JSON projection of the *displayed* aggregate. Do not make
/// Report or LocalMetricsEvent Codable here: future schema fields may contain
/// metadata that must not silently enter an exported file.
enum LocalStatisticsJSONExport {
    enum Failure: Error, Equatable { case unavailable, inconsistentSnapshot, tooLarge, encodingFailed }
    enum DisplayState: String, Encodable, Sendable { case empty, populated, partial }

    struct Input: Sendable {
        let displayState: DisplayState
        let selection: LocalStatisticsPeriod
        let result: LocalStatisticsLoadResult

        @MainActor init?(state: LocalStatisticsPageModel.State,
                         selection: LocalStatisticsPeriod) {
            switch state {
            case .empty(let result): self.init(displayState: .empty, selection: selection, result: result)
            case .populated(let result): self.init(displayState: .populated, selection: selection, result: result)
            case .partial(let result): self.init(displayState: .partial, selection: selection, result: result)
            case .notLoaded, .loading, .failed, .qaUnavailable: return nil
            }
        }

        init(displayState: DisplayState, selection: LocalStatisticsPeriod,
             result: LocalStatisticsLoadResult) {
            self.displayState = displayState
            self.selection = selection
            self.result = result
        }
    }

    private struct Provenance: Encodable {
        let dataSource = "clavuneLocalContentFreeJournal"
        let aggregation = "localStatisticsSummaryV1"
        let snapshotScope = "boundedVisibleBytePrefix"
        let writerSynchronizationBarrier = false
        let dataCompleteness = "unknown"
    }

    private struct Period: Encodable {
        let selection: String
        /// JSON null for retained entries: the builder's finite negative
        /// sentinel is an implementation filter, never a calendar start or
        /// historical-coverage proof.
        let startInclusiveUnixSeconds: Double?
        let endExclusiveUnixSeconds: Double
        let lowerBoundKind: String

        private enum CodingKeys: String, CodingKey {
            case selection, startInclusiveUnixSeconds, endExclusiveUnixSeconds, lowerBoundKind
        }
        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(selection, forKey: .selection)
            if let startInclusiveUnixSeconds {
                try values.encode(startInclusiveUnixSeconds, forKey: .startInclusiveUnixSeconds)
            } else { try values.encodeNil(forKey: .startInclusiveUnixSeconds) }
            try values.encode(endExclusiveUnixSeconds, forKey: .endExclusiveUnixSeconds)
            try values.encode(lowerBoundKind, forKey: .lowerBoundKind)
        }
    }

    private struct IntMeasure: Encodable {
        let statistic = "sum"
        let unit = "words"
        let value: Int?
        let observed: Int
        let unknown: Int
        init(_ measured: LocalStatisticsSummaryBuilder.Words) {
            value = measured.sum; observed = measured.observed; unknown = measured.unknown
        }
        private enum CodingKeys: String, CodingKey { case statistic, unit, value, observed, unknown }
        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(statistic, forKey: .statistic)
            try values.encode(unit, forKey: .unit)
            if let value { try values.encode(value, forKey: .value) }
            else { try values.encodeNil(forKey: .value) }
            try values.encode(observed, forKey: .observed)
            try values.encode(unknown, forKey: .unknown)
        }
    }

    private struct DoubleMeasure: Encodable {
        let statistic: String
        let unit: String
        let value: Double?
        let observed: Int
        let unknown: Int
        init(_ measured: LocalStatisticsSummaryBuilder.MeasuredDouble,
             statistic: String, unit: String) {
            self.statistic = statistic; self.unit = unit
            value = statistic == "sum" ? measured.sum : measured.mean
            observed = measured.observed; unknown = measured.unknown
        }
        private enum CodingKeys: String, CodingKey { case statistic, unit, value, observed, unknown }
        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(statistic, forKey: .statistic)
            try values.encode(unit, forKey: .unit)
            if let value { try values.encode(value, forKey: .value) }
            else { try values.encodeNil(forKey: .value) }
            try values.encode(observed, forKey: .observed)
            try values.encode(unknown, forKey: .unknown)
        }
    }

    private struct RequestedModes: Encodable {
        let auto: Int
        let germanWithEnglishTechnicalTerms: Int
        let english: Int
        let unknown: Int
        let autoRawDetectionIDPresent: Int
        let autoDetectionUnknown: Int
        init(_ counts: LocalStatisticsSummaryBuilder.RequestedLanguageCounts) {
            auto = counts.auto
            germanWithEnglishTechnicalTerms = counts.german
            english = counts.english
            unknown = counts.unknown
            // Only the count shown on screen, never the dictionary's raw IDs.
            autoRawDetectionIDPresent = counts.autoDetectedRawIDs.values.reduce(0, +)
            autoDetectionUnknown = counts.autoDetectionUnknown
        }
    }

    private struct Sessions: Encodable {
        let started: Int
        let completed: Int
        let failed: Int
        let cancelled: Int
        let interrupted: Int
        let startsWithoutRecordedOutcomeByPeriodEnd: Int
        let ambiguous: Int
        let recognizedWordsOnCompleted: IntMeasure
        let audioDurationSecondsOnCompleted: DoubleMeasure
        let decodeServiceSecondsOnCompleted: DoubleMeasure
        let endToEndSecondsOnCompleted: DoubleMeasure
        let filePreparationSecondsOnCompleted: DoubleMeasure?
        let microphoneCloseToResultSecondsOnCompleted: DoubleMeasure?
        let fullAudioWordsPerMinuteOnCompleted: DoubleMeasure
        let requestedModesOnCompleted: RequestedModes

        init(_ source: LocalStatisticsSummaryBuilder.Source) {
            started = source.started; completed = source.completed
            failed = source.failed; cancelled = source.cancelled
            interrupted = source.interrupted
            startsWithoutRecordedOutcomeByPeriodEnd = source.incompleteAtPeriodEnd
            ambiguous = source.ambiguous
            recognizedWordsOnCompleted = IntMeasure(source.recognizedWordsOnCompleted)
            audioDurationSecondsOnCompleted = DoubleMeasure(source.audioSecondsOnCompleted,
                statistic: "sum", unit: "seconds")
            decodeServiceSecondsOnCompleted = DoubleMeasure(source.decodeServiceSecondsOnCompleted,
                statistic: "mean", unit: "seconds")
            endToEndSecondsOnCompleted = DoubleMeasure(source.endToEndSecondsOnCompleted,
                statistic: "mean", unit: "seconds")
            filePreparationSecondsOnCompleted = source.kind == .audioFile
                ? DoubleMeasure(source.filePreparationSecondsOnCompleted,
                    statistic: "mean", unit: "seconds") : nil
            microphoneCloseToResultSecondsOnCompleted = source.kind == .microphone
                ? DoubleMeasure(source.captureToResultSecondsOnCompleted,
                    statistic: "mean", unit: "seconds") : nil
            fullAudioWordsPerMinuteOnCompleted = DoubleMeasure(source.audioWordRateOnCompleted,
                statistic: "meanOfPerSessionFullAudioRates", unit: "wordsPerMinuteFullAudio")
            requestedModesOnCompleted = RequestedModes(source.requestedLanguageOnCompleted)
        }
    }

    private struct ReviewCount: Encodable {
        let attempts: Int
        let succeeded: Int
        let notSucceeded: Int
        init(_ counts: LocalStatisticsSummaryBuilder.ReviewCounts) {
            attempts = counts.attempts; succeeded = counts.succeeded
            notSucceeded = counts.notSucceeded
        }
    }

    private struct Reviews: Encodable {
        let copy: ReviewCount
        let save: ReviewCount
        let open: ReviewCount
        let discard: ReviewCount
        let cancel: ReviewCount
        init(_ reviews: LocalStatisticsSummaryBuilder.Reviews) {
            copy = ReviewCount(reviews.copy); save = ReviewCount(reviews.save)
            open = ReviewCount(reviews.open); discard = ReviewCount(reviews.discard)
            cancel = ReviewCount(reviews.cancel)
        }
    }

    private struct Source: Encodable {
        let kind: String
        let sessions: Sessions?
        let reviews: Reviews
        init(_ source: LocalStatisticsSummaryBuilder.Source, kind: String) {
            self.kind = kind
            sessions = source.kind == .transcriptFile ? nil : Sessions(source)
            reviews = Reviews(source.reviews)
        }
    }

    private struct Diagnostics: Encodable {
        let skippedJournalFiles: Int
        let invalidJournalRecords: Int
        let tornFileTails: Int
        let concurrentChangeDetected: Bool
        let readerMarkedPartial: Bool
        let duplicateEventRecords: Int
        let conflictingEventIDGroups: Int
        let invalidTimestampEvents: Int
        let unsupportedSchemaEvents: Int
        let invalidRecordEvents: Int
        let orphanTerminalSessions: Int
        let orphanReviewEvents: Int
        init(_ result: LocalStatisticsLoadResult) {
            let read = result.diagnostics, report = result.report
            skippedJournalFiles = read.skippedFiles
            invalidJournalRecords = read.malformedRecords
            tornFileTails = read.tornTailFiles
            concurrentChangeDetected = read.concurrentChangeDetected
            readerMarkedPartial = read.readerMarkedPartial
            duplicateEventRecords = report.duplicateEventRecords
            conflictingEventIDGroups = report.conflictingEventIDGroups
            invalidTimestampEvents = report.invalidTimestampEvents
            unsupportedSchemaEvents = report.unsupportedSchemaEvents
            invalidRecordEvents = report.invalidRecordEvents
            orphanTerminalSessions = report.orphanTerminalSessions
            orphanReviewEvents = report.orphanReviewEvents
        }
    }

    private struct Document: Encodable {
        let formatVersion = 1
        let metricDefinitionVersion = 1
        let provenance = Provenance()
        let metricSemantics = MetricSemantics()
        let historicalCoverageUnknown: Bool
        let displayState: DisplayState
        let visiblePrefixReaderState: String
        let period: Period
        let readCompletedAtUnixSeconds: Double
        let exportGeneratedAtUnixSeconds: Double
        let diagnostics: Diagnostics
        let sources: [Source]
    }

    private struct MetricSemantics: Encodable {
        let startsAndOutcomesUseOwnEventTimestamps = true
        let wordRateAndTimingMeasuresAreCompletedOnly = true
        let notSucceededMayIncludePickerCancellation = true
        let decodeServiceIncludesResultExtraction = true
        let audioImportEndToEndStartsAfterFilePicker = true
        let wordRate = "arithmeticMeanOfPerSessionFullAudioRatesIncludingPauses"
        let accuracyTimeSavedGPUAndEnergyAreNotMeasured = true
    }

    static func encode(_ input: Input, generatedAt: Date = Date()) throws -> String {
        let result = input.result, report = result.report
        guard let reader = result.diagnostics.readerState, reader != .unavailable,
              report.historicalCoverageUnknown,
              result.loadedAt.timeIntervalSince1970.isFinite,
              generatedAt.timeIntervalSince1970.isFinite,
              (try? input.selection.interval(endingAt: report.period.endExclusive)) == report.period,
              (reader == .partial) == result.isPartial else {
            throw Failure.inconsistentSnapshot
        }
        switch input.displayState {
        case .empty:
            guard !result.isPartial, !result.hasEventsInPeriod else { throw Failure.inconsistentSnapshot }
        case .populated:
            guard !result.isPartial, result.hasEventsInPeriod else { throw Failure.inconsistentSnapshot }
        case .partial:
            guard result.isPartial else { throw Failure.inconsistentSnapshot }
        }
        if reader == .validEmpty, report.suppliedEventCount != 0 {
            throw Failure.inconsistentSnapshot
        }
        if reader == .complete, report.suppliedEventCount == 0 {
            throw Failure.inconsistentSnapshot
        }
        let period = Period(selection: input.selection.rawValue,
            startInclusiveUnixSeconds: input.selection == .retained ? nil
                : report.period.start.timeIntervalSince1970,
            endExclusiveUnixSeconds: report.period.endExclusive.timeIntervalSince1970,
            lowerBoundKind: input.selection == .retained
                ? "unreportedFiniteFilterSentinelNotCoverageStart" : "inclusive")
        let document = Document(historicalCoverageUnknown: true,
            displayState: input.displayState, visiblePrefixReaderState: reader.rawValue,
            period: period, readCompletedAtUnixSeconds: result.loadedAt.timeIntervalSince1970,
            exportGeneratedAtUnixSeconds: generatedAt.timeIntervalSince1970,
            diagnostics: Diagnostics(result), sources: [
                Source(report.microphone, kind: "microphone"),
                Source(report.audioFile, kind: "audioFile"),
                Source(report.transcriptFile, kind: "transcriptFile")
            ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let bytes: Data
        do { bytes = try encoder.encode(document) }
        catch { throw Failure.encodingFailed }
        guard bytes.count <= 64 * 1024 else { throw Failure.tooLarge }
        guard let text = String(data: bytes, encoding: .utf8) else { throw Failure.encodingFailed }
        return text
    }
}
