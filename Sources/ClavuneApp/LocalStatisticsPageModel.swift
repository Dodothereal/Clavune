import ClavuneCore
import Combine
import Foundation

enum LocalStatisticsPeriod: String, CaseIterable, Identifiable, Sendable {
    case last24Hours, last7Days, last30Days, retained
    var id: String { rawValue }

    func interval(endingAt end: Date) throws -> LocalStatisticsSummaryBuilder.Period {
        let start: Date
        switch self {
        case .last24Hours: start = end.addingTimeInterval(-86_400)
        case .last7Days: start = end.addingTimeInterval(-7 * 86_400)
        case .last30Days: start = end.addingTimeInterval(-30 * 86_400)
        // The writer accepts any finite event timestamp, including a clock set
        // before 1970. A retained-data window must not silently drop those.
        case .retained: start = Date(timeIntervalSince1970: -Double.greatestFiniteMagnitude)
        }
        return try LocalStatisticsSummaryBuilder.Period(start: start, endExclusive: end)
    }
}

/// Only counts and flags, never a raw record, path, transcript or error text.
struct LocalStatisticsReadDiagnostics: Sendable, Equatable {
    /// Exact Core reader result, not the page's selected-period empty/populated
    /// state. A complete visible-prefix read may still have no event in period.
    var readerState: LocalMetricsSnapshotReader.State?
    var readFiles = 0
    var skippedFiles = 0
    var malformedRecords = 0
    var tornTailFiles = 0
    var concurrentChangeDetected = false
    var readerMarkedPartial = false

    var hasDamage: Bool {
        skippedFiles > 0 || malformedRecords > 0 || tornTailFiles > 0 ||
            concurrentChangeDetected || readerMarkedPartial || readerState == .partial
    }
}

struct LocalStatisticsLoadResult: Sendable, Equatable {
    let report: LocalStatisticsSummaryBuilder.Report
    let diagnostics: LocalStatisticsReadDiagnostics
    let loadedAt: Date

    var isPartial: Bool {
        diagnostics.hasDamage || report.duplicateEventRecords > 0 ||
            report.conflictingEventIDGroups > 0 || report.unsupportedSchemaEvents > 0 ||
            report.invalidTimestampEvents > 0 || report.invalidRecordEvents > 0 ||
            report.orphanTerminalSessions > 0 || report.orphanReviewEvents > 0 ||
            report.microphone.ambiguous > 0 || report.audioFile.ambiguous > 0
    }

    var hasEventsInPeriod: Bool {
        sourceHasEvents(report.microphone) || sourceHasEvents(report.audioFile) ||
            sourceHasEvents(report.transcriptFile)
    }

    private func sourceHasEvents(_ source: LocalStatisticsSummaryBuilder.Source) -> Bool {
        let sessions = source.started > 0 || source.completed > 0 || source.failed > 0 ||
            source.cancelled > 0 || source.interrupted > 0 ||
            source.incompleteAtPeriodEnd > 0 || source.ambiguous > 0
        let reviews = source.reviews
        let actions = reviews.copy.attempts > 0 || reviews.save.attempts > 0 ||
            reviews.open.attempts > 0 || reviews.discard.attempts > 0 ||
            reviews.cancel.attempts > 0
        return sessions || actions
    }
}

enum LocalStatisticsFailure: Sendable, Equatable {
    case unavailable, unsafeFiles, readFailed, aggregationFailed
}

/// A small main-actor presentation state machine. The injected loader performs
/// all disk I/O and aggregation away from MainActor. Refresh has no timer and
/// never touches coordinator/session/editor/Undo state.
@MainActor
final class LocalStatisticsPageModel: ObservableObject {
    typealias Loader = @Sendable (LocalStatisticsSummaryBuilder.Period) async throws -> LocalStatisticsLoadResult
    enum State: Equatable {
        case notLoaded, loading, empty(LocalStatisticsLoadResult)
        case populated(LocalStatisticsLoadResult), partial(LocalStatisticsLoadResult)
        case failed(LocalStatisticsFailure), qaUnavailable
    }

    @Published private(set) var state: State = .notLoaded
    @Published private(set) var selectedPeriod: LocalStatisticsPeriod = .last7Days
    private let loader: Loader
    private let now: @Sendable () -> Date
    private var generation: UInt64 = 0
    private var activeTask: Task<Void, Never>?

    init(loader: @escaping Loader, now: @escaping @Sendable () -> Date = { Date() }) {
        self.loader = loader; self.now = now
    }

    @discardableResult
    func selectPeriod(_ period: LocalStatisticsPeriod, qaDisabled: Bool = false) -> Task<Void, Never>? {
        guard period != selectedPeriod else { return nil }
        selectedPeriod = period
        return refresh(qaDisabled: qaDisabled)
    }

    @discardableResult
    func refresh(qaDisabled: Bool = false) -> Task<Void, Never>? {
        generation &+= 1
        activeTask?.cancel()
        activeTask = nil
        guard !qaDisabled else { state = .qaUnavailable; return nil }
        let period: LocalStatisticsSummaryBuilder.Period
        do { period = try selectedPeriod.interval(endingAt: now()) }
        catch { state = .failed(.aggregationFailed); return nil }
        let request = generation
        let loader = self.loader
        state = .loading
        let task = Task { [weak self] in
            do {
                let result = try await loader(period)
                guard let self, self.generation == request, !Task.isCancelled else { return }
                guard result.report.period == period else {
                    self.state = .failed(.aggregationFailed)
                    return
                }
                if result.isPartial { self.state = .partial(result) }
                else if result.hasEventsInPeriod { self.state = .populated(result) }
                else { self.state = .empty(result) }
            } catch {
                guard let self, self.generation == request, !Task.isCancelled else { return }
                self.state = .failed(Self.failureKind(error))
            }
        }
        activeTask = task
        return task
    }

    func leave() {
        generation &+= 1
        activeTask?.cancel()
        activeTask = nil
        state = .notLoaded
    }

    private static func failureKind(_ error: Error) -> LocalStatisticsFailure {
        if let error = error as? LocalStatisticsDiskLoader.Failure {
            switch error {
            case .unavailable: return .unavailable
            case .unsafeFiles: return .unsafeFiles
            case .readFailed: return .readFailed
            case .aggregationFailed: return .aggregationFailed
            }
        }
        return .readFailed
    }
}
