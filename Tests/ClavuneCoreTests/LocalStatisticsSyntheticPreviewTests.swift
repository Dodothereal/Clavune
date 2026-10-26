import Foundation
import XCTest
@testable import ClavuneApp
@testable import ClavuneCore

final class LocalStatisticsSyntheticPreviewTests: XCTestCase {
    func testFixedInMemoryPreviewChangesAcrossRollingPeriods() async throws {
        let now = LocalStatisticsSyntheticPreview.referenceTime
        func load(_ selection: LocalStatisticsPeriod) async throws -> LocalStatisticsLoadResult {
            try await LocalStatisticsSyntheticPreview.load(selection.interval(endingAt: now))
        }
        let day = try await load(.last24Hours)
        let week = try await load(.last7Days)
        let month = try await load(.last30Days)
        let retained = try await load(.retained)

        XCTAssertEqual(day.report.microphone.started, 1)
        XCTAssertEqual(day.report.microphone.completed, 1)
        XCTAssertEqual(day.report.audioFile.started, 0)
        XCTAssertEqual(day.report.microphone.recognizedWordsOnCompleted.sum, 90)
        XCTAssertEqual(day.report.microphone.audioWordRateOnCompleted.mean, 90)
        XCTAssertEqual(week.report.audioFile.started, 1)
        XCTAssertEqual(week.report.audioFile.completed, 1)
        XCTAssertEqual(week.report.audioFile.recognizedWordsOnCompleted.sum, 40)
        XCTAssertEqual(month.report.transcriptFile.reviews.open.succeeded, 1)
        XCTAssertEqual(retained.report.microphone.failed, 1)
        XCTAssertEqual(day.loadedAt, now)
        XCTAssertEqual(day.diagnostics.readFiles, 0)
        let repeated = try await load(.last24Hours)
        XCTAssertEqual(day, repeated)
    }
}
