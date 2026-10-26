import Foundation
import XCTest
@testable import ClavuneApp
@testable import ClavuneCore

/// Synthetic, in-memory state tests. The loader intentionally ignores task
/// cancellation so only the page generation fence can reject late results.
final class LocalStatisticsPageRaceTests: XCTestCase {
    private actor HeldLoader {
        typealias Period = LocalStatisticsSummaryBuilder.Period
        private struct Request {
            let period: Period
            let completion: CheckedContinuation<LocalStatisticsLoadResult, Error>
        }
        private var nextID = 0
        private var requests: [Int: Request] = [:]
        private var arrivals: [Int: CheckedContinuation<Void, Never>] = [:]

        func load(_ period: Period) async throws -> LocalStatisticsLoadResult {
            let id = nextID
            nextID += 1
            return try await withCheckedThrowingContinuation { completion in
                requests[id] = Request(period: period, completion: completion)
                arrivals.removeValue(forKey: id)?.resume()
            }
        }

        func waitForRequest(_ id: Int) async -> Period {
            if requests[id] == nil {
                await withCheckedContinuation { arrivals[id] = $0 }
            }
            return requests[id]!.period
        }

        func requestCount() -> Int { nextID }

        func succeed(_ id: Int, with result: LocalStatisticsLoadResult) {
            requests.removeValue(forKey: id)!.completion.resume(returning: result)
        }

        func fail(_ id: Int, with error: Error) {
            requests.removeValue(forKey: id)!.completion.resume(throwing: error)
        }
    }

    private struct SyntheticReadFailure: Error {}
    private let fixedNow = Date(timeIntervalSince1970: 1_000_000)

    private func result(_ period: LocalStatisticsSummaryBuilder.Period,
                        starts: Int = 0, malformed: Int = 0) throws -> LocalStatisticsLoadResult {
        let events = (0..<starts).map { offset in
            let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", offset + 1))!
            return LocalMetricsEvent(eventID: id, sessionID: id,
                timestamp: period.endExclusive.addingTimeInterval(Double(-10 - offset)),
                kind: .sessionStarted, source: .microphone)
        }
        let report = try LocalStatisticsSummaryBuilder.build(events: events, period: period)
        var diagnostics = LocalStatisticsReadDiagnostics()
        diagnostics.malformedRecords = malformed
        return LocalStatisticsLoadResult(report: report, diagnostics: diagnostics, loadedAt: fixedNow)
    }

    @MainActor func testNewerRefreshWinsOverLateSuccessAndFailure() async throws {
        let gate = HeldLoader()
        let model = LocalStatisticsPageModel(loader: { try await gate.load($0) },
                                             now: { Date(timeIntervalSince1970: 1_000_000) })
        XCTAssertEqual(model.state, .notLoaded)
        let initialRequests = await gate.requestCount()
        XCTAssertEqual(initialRequests, 0, "Constructing the state model must not begin a read")
        let first = try XCTUnwrap(model.refresh())
        let periodA = await gate.waitForRequest(0)
        let second = try XCTUnwrap(model.refresh())
        let periodB = await gate.waitForRequest(1)
        let newer = try result(periodB, starts: 2)
        await gate.succeed(1, with: newer)
        await second.value
        XCTAssertEqual(model.state, .populated(newer))
        await gate.succeed(0, with: try result(periodA, starts: 1))
        await first.value
        XCTAssertEqual(model.state, .populated(newer), "A cancelled loader can still return; it must not publish")

        let staleFailure = try XCTUnwrap(model.refresh())
        _ = await gate.waitForRequest(2)
        let newest = try XCTUnwrap(model.refresh())
        let newestPeriod = await gate.waitForRequest(3)
        let newestResult = try result(newestPeriod, starts: 3)
        await gate.succeed(3, with: newestResult)
        await newest.value
        await gate.fail(2, with: SyntheticReadFailure())
        await staleFailure.value
        XCTAssertEqual(model.state, .populated(newestResult), "An old error must not replace newer counts")
        let requestCount = await gate.requestCount()
        XCTAssertEqual(requestCount, 4)
    }

    @MainActor func testLeaveAndReopenRejectOldVisitEvenIfCancellationIsIgnored() async throws {
        let gate = HeldLoader()
        let model = LocalStatisticsPageModel(loader: { try await gate.load($0) },
                                             now: { Date(timeIntervalSince1970: 1_000_000) })
        let oldVisit = try XCTUnwrap(model.refresh())
        let oldPeriod = await gate.waitForRequest(0)
        model.leave()
        XCTAssertEqual(model.state, .notLoaded)
        let newVisit = try XCTUnwrap(model.refresh())
        let newPeriod = await gate.waitForRequest(1)
        await gate.succeed(0, with: try result(oldPeriod, starts: 1))
        await oldVisit.value
        XCTAssertEqual(model.state, .loading, "Old visit may not populate a reopened page")
        let newResult = try result(newPeriod, starts: 2)
        await gate.succeed(1, with: newResult)
        await newVisit.value
        XCTAssertEqual(model.state, .populated(newResult))

        let dismissed = try XCTUnwrap(model.refresh())
        _ = await gate.waitForRequest(2)
        model.leave()
        await gate.fail(2, with: SyntheticReadFailure())
        await dismissed.value
        XCTAssertEqual(model.state, .notLoaded, "Old failure may not surface after leave")
    }

    @MainActor func testEmptyPartialFailureAndQAUnavailableAreDistinct() async throws {
        let gate = HeldLoader()
        let model = LocalStatisticsPageModel(loader: { try await gate.load($0) },
                                             now: { Date(timeIntervalSince1970: 1_000_000) })
        let emptyTask = try XCTUnwrap(model.refresh())
        let emptyPeriod = await gate.waitForRequest(0)
        let empty = try result(emptyPeriod)
        await gate.succeed(0, with: empty)
        await emptyTask.value
        XCTAssertEqual(model.state, .empty(empty))
        XCTAssertTrue(empty.report.historicalCoverageUnknown)

        let partialTask = try XCTUnwrap(model.refresh())
        let partialPeriod = await gate.waitForRequest(1)
        let partial = try result(partialPeriod, malformed: 1)
        await gate.succeed(1, with: partial)
        await partialTask.value
        XCTAssertEqual(model.state, .partial(partial), "Partial empty data is not valid empty history")

        let failedTask = try XCTUnwrap(model.refresh())
        _ = await gate.waitForRequest(2)
        await gate.fail(2, with: SyntheticReadFailure())
        await failedTask.value
        XCTAssertEqual(model.state, .failed(.readFailed))

        XCTAssertNil(model.refresh(qaDisabled: true))
        XCTAssertEqual(model.state, .qaUnavailable)
        let requestCount = await gate.requestCount()
        XCTAssertEqual(requestCount, 3, "QA must never invoke the loader")

        // Even if an app host flips its QA gate while a normal read is held,
        // the cancelled normal-profile result must not appear in the QA state.
        let beforeQASwitch = try XCTUnwrap(model.refresh())
        let heldPeriod = await gate.waitForRequest(3)
        XCTAssertNil(model.refresh(qaDisabled: true))
        XCTAssertEqual(model.state, .qaUnavailable)
        await gate.succeed(3, with: try result(heldPeriod, starts: 1))
        await beforeQASwitch.value
        XCTAssertEqual(model.state, .qaUnavailable)
        let finalRequestCount = await gate.requestCount()
        XCTAssertEqual(finalRequestCount, 4)
    }

    @MainActor func testFailedRefreshRemovesPreviouslyPopulatedSnapshot() async throws {
        let gate = HeldLoader()
        let model = LocalStatisticsPageModel(loader: { try await gate.load($0) },
                                             now: { Date(timeIntervalSince1970: 1_000_000) })
        let first = try XCTUnwrap(model.refresh())
        let period = await gate.waitForRequest(0)
        let populated = try result(period, starts: 2)
        await gate.succeed(0, with: populated)
        await first.value
        XCTAssertEqual(model.state, .populated(populated))

        let refresh = try XCTUnwrap(model.refresh())
        _ = await gate.waitForRequest(1)
        XCTAssertEqual(model.state, .loading, "A refresh must not display old counts as current")
        await gate.fail(1, with: SyntheticReadFailure())
        await refresh.value
        XCTAssertEqual(model.state, .failed(.readFailed),
                       "A failed read must not retain the last successful snapshot")
    }

    @MainActor func testPeriodChangeKeepsPeriodAndReportTogether() async throws {
        let gate = HeldLoader()
        let model = LocalStatisticsPageModel(loader: { try await gate.load($0) },
                                             now: { Date(timeIntervalSince1970: 1_000_000) })
        let oldTask = try XCTUnwrap(model.refresh())
        let oldPeriod = await gate.waitForRequest(0)
        let newTask = try XCTUnwrap(model.selectPeriod(.last24Hours))
        let newPeriod = await gate.waitForRequest(1)
        XCTAssertNotEqual(oldPeriod, newPeriod)
        let newResult = try result(newPeriod, starts: 2)
        await gate.succeed(1, with: newResult)
        await newTask.value
        await gate.succeed(0, with: try result(oldPeriod, starts: 1))
        await oldTask.value
        XCTAssertEqual(model.selectedPeriod, .last24Hours)
        XCTAssertEqual(model.state, .populated(newResult))
        XCTAssertEqual(newResult.report.period, newPeriod)
    }

    @MainActor func testRejectedTimestampDoesNotBecomeValidEmptyHistory() async throws {
        let gate = HeldLoader()
        let model = LocalStatisticsPageModel(loader: { try await gate.load($0) },
                                             now: { Date(timeIntervalSince1970: 1_000_000) })
        let task = try XCTUnwrap(model.refresh())
        let period = await gate.waitForRequest(0)
        let invalidID = UUID(uuidString: "00000000-0000-0000-0000-0000000000FF")!
        let invalid = LocalMetricsEvent(eventID: invalidID, sessionID: invalidID,
            timestamp: Date(timeIntervalSince1970: .nan),
            kind: .sessionStarted, source: .microphone)
        let report = try LocalStatisticsSummaryBuilder.build(events: [invalid], period: period)
        XCTAssertEqual(report.invalidTimestampEvents, 1)
        let damaged = LocalStatisticsLoadResult(report: report,
            diagnostics: LocalStatisticsReadDiagnostics(), loadedAt: fixedNow)
        await gate.succeed(0, with: damaged)
        await task.value
        XCTAssertEqual(model.state, .partial(damaged), "Discarded source data cannot be shown as valid empty")
    }

    func testAmbiguousAssociationCannotBePresentedAsCompleteWithoutReaderFlag() throws {
        let period = try LocalStatisticsPeriod.last7Days.interval(endingAt: fixedNow)
        let session = UUID()
        let start = LocalMetricsEvent(sessionID: session,
            timestamp: period.endExclusive.addingTimeInterval(-10),
            kind: .sessionStarted, source: .microphone)
        let reversed = LocalMetricsEvent(sessionID: session,
            timestamp: period.endExclusive.addingTimeInterval(-20),
            kind: .transcriptionCompleted, source: .microphone)
        let report = try LocalStatisticsSummaryBuilder.build(events: [start, reversed], period: period)
        XCTAssertEqual(report.microphone.ambiguous, 1)
        let result = LocalStatisticsLoadResult(report: report,
            diagnostics: LocalStatisticsReadDiagnostics(), loadedAt: fixedNow)
        XCTAssertTrue(result.isPartial)
    }

    @MainActor func testLoaderCannotPublishReportForWrongPeriod() async throws {
        let gate = HeldLoader()
        let model = LocalStatisticsPageModel(loader: { try await gate.load($0) },
                                             now: { Date(timeIntervalSince1970: 1_000_000) })
        let task = try XCTUnwrap(model.refresh())
        let requested = await gate.waitForRequest(0)
        let wrongPeriod = try LocalStatisticsPeriod.last24Hours.interval(endingAt: fixedNow)
        XCTAssertNotEqual(requested, wrongPeriod)
        await gate.succeed(0, with: try result(wrongPeriod, starts: 2))
        await task.value
        XCTAssertEqual(model.selectedPeriod, .last7Days)
        XCTAssertEqual(model.state, .failed(.aggregationFailed),
                       "Counts for a different period must not appear under the selected picker")
    }
}
