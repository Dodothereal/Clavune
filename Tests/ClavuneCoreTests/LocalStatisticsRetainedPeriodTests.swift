import Foundation
import XCTest
@testable import ClavuneApp
@testable import ClavuneCore

/// Synthetic clock-regression contract: "retained" may not mean "since 1970".
final class LocalStatisticsRetainedPeriodTests: XCTestCase {
    func testRollingWindowsEndAtRefreshInstantWithoutCalendarRounding() throws {
        let now = Date(timeIntervalSince1970: 1_000_123.5)
        let cases: [(LocalStatisticsPeriod, TimeInterval)] = [
            (.last24Hours, 86_400), (.last7Days, 604_800), (.last30Days, 2_592_000)
        ]
        for (choice, seconds) in cases {
            let window = try choice.interval(endingAt: now)
            XCTAssertEqual(window.start, now.addingTimeInterval(-seconds))
            XCTAssertEqual(window.endExclusive, now)
        }
    }

    func testRetainedWindowIncludesValidPreEpochEvent() throws {
        let window = try LocalStatisticsPeriod.retained.interval(
            endingAt: Date(timeIntervalSince1970: 100))
        let id = UUID()
        let event = LocalMetricsEvent(eventID: id, sessionID: id,
            timestamp: Date(timeIntervalSince1970: -100),
            kind: .sessionStarted, source: .microphone)
        let report = try LocalStatisticsSummaryBuilder.build(events: [event], period: window)
        XCTAssertEqual(report.microphone.started, 1)
        XCTAssertEqual(report.microphone.incompleteAtPeriodEnd, 1)
        XCTAssertTrue(report.historicalCoverageUnknown)
    }
}
