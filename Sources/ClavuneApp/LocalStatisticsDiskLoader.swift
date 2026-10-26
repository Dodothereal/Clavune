import ClavuneCore
import Foundation

/// The only production Statistics I/O boundary. It never publishes raw events
/// or user paths to SwiftUI, and never synchronously enters disk aggregation on
/// MainActor. The reader captures a bounded visible-byte prefix, not a writer
/// synchronization barrier or proof of durable/complete history.
enum LocalStatisticsDiskLoader {
    enum Failure: Error, Sendable {
        case unavailable, unsafeFiles, readFailed, aggregationFailed
    }

    /// Rapid refreshes cannot launch overlapping 10 MiB journal scans. A
    /// cancelled request waiting its turn exits before disk I/O begins.
    private actor ReaderGate {
        static let shared = ReaderGate()
        func read(directoryURL: URL, period: LocalStatisticsSummaryBuilder.Period) throws
            -> LocalMetricsSnapshotReader.Result {
            guard !Task.isCancelled else { throw CancellationError() }
            return LocalMetricsSnapshotReader.readSummary(directoryURL: directoryURL, period: period)
        }
    }

    static func load(_ period: LocalStatisticsSummaryBuilder.Period) async throws -> LocalStatisticsLoadResult {
        guard !Task.isCancelled else { throw CancellationError() }
        let work = Task.detached(priority: .utility) { () throws -> LocalStatisticsLoadResult in
            guard let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                         in: .userDomainMask).first else {
                throw Failure.unavailable
            }
            let directory = support.appendingPathComponent("Clavune/Metrics", isDirectory: true)
            let snapshot = try await ReaderGate.shared.read(directoryURL: directory, period: period)
            let read = snapshot.diagnostics
            guard let report = snapshot.summary else {
                switch read.unavailableReason {
                case .cancelled: throw CancellationError()
                case .directoryUnsafe: throw Failure.unsafeFiles
                case .aggregationRejected: throw Failure.aggregationFailed
                case .invalidLimits, .enumerationFailed, .capacityExceeded: throw Failure.readFailed
                case .directoryUnavailable, nil: throw Failure.unavailable
                }
            }
            var diagnostics = LocalStatisticsReadDiagnostics()
            diagnostics.readerState = read.state
            diagnostics.readFiles = read.segmentCount
            diagnostics.skippedFiles = read.unsafeOrUnreadableSegmentCount
            diagnostics.malformedRecords = read.invalidRecordCount
            diagnostics.tornTailFiles = read.tornTailCount
            diagnostics.concurrentChangeDetected = read.concurrentChangeDetected
            diagnostics.readerMarkedPartial = read.state == .partial
            return LocalStatisticsLoadResult(report: report, diagnostics: diagnostics, loadedAt: Date())
        }
        return try await withTaskCancellationHandler(operation: {
            try await work.value
        }, onCancel: { work.cancel() })
    }
}
