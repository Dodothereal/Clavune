import Foundation
import XCTest
@testable import ClavuneApp
@testable import ClavuneCore

/// Pure synthetic projection tests. Never opens a Save panel, reads a normal
/// journal, writes a user destination, or exercises an OS clipboard.
final class LocalStatisticsJSONExportTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000.125)

    private func event(_ session: UUID, _ when: Date, _ kind: LocalMetricsEvent.Kind,
                       words: Int? = nil, audio: Double? = nil, rate: Double? = nil,
                       name: String? = nil, eventID: UUID = UUID(),
                       hash: String? = nil, backend: String? = nil,
                       rawWords: Int? = nil, editedWords: Int? = nil) -> LocalMetricsEvent {
        LocalMetricsEvent(eventID: eventID, sessionID: session, timestamp: when,
            kind: kind, source: .microphone, requestedLanguage: "auto",
            detectedLanguageID: kind == .transcriptionCompleted ? 7 : nil,
            modelFileName: name, modelSHA256: hash, backendFingerprint: backend,
            audioDurationSeconds: audio, recognizedWordCount: words,
            wordsPerMinute: rate, rawWordCount: rawWords, editedWordCount: editedWords)
    }

    private func result(_ events: [LocalMetricsEvent], selection: LocalStatisticsPeriod = .last7Days,
                        reader: LocalMetricsSnapshotReader.State? = nil,
                        malformed: Int = 0) throws -> LocalStatisticsLoadResult {
        let period = try selection.interval(endingAt: now)
        let report = try LocalStatisticsSummaryBuilder.build(events: events, period: period)
        var diagnostics = LocalStatisticsReadDiagnostics()
        let actualReader = reader ?? (events.isEmpty ? .validEmpty : .complete)
        diagnostics.readerState = actualReader
        diagnostics.readerMarkedPartial = actualReader == .partial
        diagnostics.malformedRecords = malformed
        return LocalStatisticsLoadResult(report: report, diagnostics: diagnostics, loadedAt: now)
    }

    private func json(_ input: LocalStatisticsJSONExport.Input) throws -> [String: Any] {
        let text = try LocalStatisticsJSONExport.encode(input, generatedAt: now.addingTimeInterval(2))
        XCTAssertLessThanOrEqual(text.utf8.count, 64 * 1024)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func mic(_ document: [String: Any]) throws -> [String: Any] {
        let sources = try XCTUnwrap(document["sources"] as? [[String: Any]])
        return try XCTUnwrap(sources.first { $0["kind"] as? String == "microphone" })
    }

    func testFixedProjectionHasTrueZeroUnknownAndNoPrivateCanaries() throws {
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let eventID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let second = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let modelHash = String(repeating: "A", count: 64)
        let backendHash = String(repeating: "B", count: 64)
        let events = [
            event(id, now.addingTimeInterval(-100), .sessionStarted, name: "private-canary.ggml"),
            event(id, now.addingTimeInterval(-90), .transcriptionCompleted,
                  words: 0, audio: 10, rate: 0, name: "private-canary.ggml", eventID: eventID,
                  hash: modelHash, backend: backendHash, rawWords: 12345, editedWords: 54321),
            event(second, now.addingTimeInterval(-80), .sessionStarted),
            event(second, now.addingTimeInterval(-70), .transcriptionCompleted)
        ]
        let value = try result(events)
        let input = LocalStatisticsJSONExport.Input(displayState: .populated,
                                                     selection: .last7Days, result: value)
        let text = try LocalStatisticsJSONExport.encode(input, generatedAt: now)
        for secret in ["private-canary", id.uuidString, eventID.uuidString, modelHash,
                       backendHash, "modelFileName", "modelSHA256", "backendFingerprint",
                       "sessionID", "eventID", "rawWordCount", "editedWordCount",
                       "failureCode", "autoDetectedRawIDs"] {
            XCTAssertFalse(text.contains(secret), "Export must not leak \(secret)")
        }
        XCTAssertFalse(text.contains("\"transcript\":"))
        XCTAssertFalse(text.contains("\"path\":"))
        let document = try json(input)
        let sessions = try XCTUnwrap(mic(document)["sessions"] as? [String: Any])
        let words = try XCTUnwrap(sessions["recognizedWordsOnCompleted"] as? [String: Any])
        XCTAssertEqual(words["value"] as? Int, 0)
        XCTAssertEqual(words["observed"] as? Int, 1)
        XCTAssertEqual(words["unknown"] as? Int, 1)
        let audio = try XCTUnwrap(sessions["audioDurationSecondsOnCompleted"] as? [String: Any])
        XCTAssertEqual(audio["value"] as? Double, 10)
        let rate = try XCTUnwrap(sessions["fullAudioWordsPerMinuteOnCompleted"] as? [String: Any])
        XCTAssertEqual(rate["value"] as? Double, 0)
        XCTAssertEqual(rate["observed"] as? Int, 1)
        let provenance = try XCTUnwrap(document["provenance"] as? [String: Any])
        XCTAssertEqual(provenance["writerSynchronizationBarrier"] as? Bool, false)
        XCTAssertEqual(document["historicalCoverageUnknown"] as? Bool, true)
    }

    func testReaderCompleteButPeriodEmptyIsNotValidEmpty() throws {
        let session = UUID()
        let events = [
            event(session, now.addingTimeInterval(-9 * 86_400), .sessionStarted),
            event(session, now.addingTimeInterval(-9 * 86_400 + 10), .transcriptionCompleted)
        ]
        let value = try result(events)
        XCTAssertFalse(value.hasEventsInPeriod)
        let input = LocalStatisticsJSONExport.Input(displayState: .empty,
                                                     selection: .last7Days, result: value)
        let document = try json(input)
        XCTAssertEqual(document["displayState"] as? String, "empty")
        XCTAssertEqual(document["visiblePrefixReaderState"] as? String, "complete")
        XCTAssertEqual(document["historicalCoverageUnknown"] as? Bool, true)
        let sessions = try XCTUnwrap(mic(document)["sessions"] as? [String: Any])
        let words = try XCTUnwrap(sessions["recognizedWordsOnCompleted"] as? [String: Any])
        XCTAssertTrue(words["value"] is NSNull)
        XCTAssertEqual(words["observed"] as? Int, 0)
    }

    func testCompletedSessionWithUnknownMeasurementsUsesNullNotMeasuredZero() throws {
        let id = UUID()
        let value = try result([
            event(id, now.addingTimeInterval(-20), .sessionStarted),
            event(id, now.addingTimeInterval(-10), .transcriptionCompleted)
        ])
        let document = try json(.init(displayState: .populated,
                                      selection: .last7Days, result: value))
        let sessions = try XCTUnwrap(mic(document)["sessions"] as? [String: Any])
        let words = try XCTUnwrap(sessions["recognizedWordsOnCompleted"] as? [String: Any])
        XCTAssertTrue(words["value"] is NSNull)
        XCTAssertEqual(words["observed"] as? Int, 0)
        XCTAssertEqual(words["unknown"] as? Int, 1)
        let rate = try XCTUnwrap(sessions["fullAudioWordsPerMinuteOnCompleted"] as? [String: Any])
        XCTAssertTrue(rate["value"] is NSNull)
        XCTAssertEqual(rate["observed"] as? Int, 0)
        XCTAssertEqual(rate["unknown"] as? Int, 1)
    }

    func testPartialWithoutInPeriodEventsIsStillPartial() throws {
        let value = try result([], reader: .partial, malformed: 1)
        let document = try json(.init(displayState: .partial,
                                      selection: .last7Days, result: value))
        XCTAssertEqual(document["displayState"] as? String, "partial")
        XCTAssertEqual(document["visiblePrefixReaderState"] as? String, "partial")
        let diagnostics = try XCTUnwrap(document["diagnostics"] as? [String: Any])
        XCTAssertEqual(diagnostics["invalidJournalRecords"] as? Int, 1)
    }

    func testRetainedSentinelIsNotPresentedAsObservedHistoryStart() throws {
        let value = try result([], selection: .retained, reader: .validEmpty)
        let document = try json(.init(displayState: .empty,
                                      selection: .retained, result: value))
        let period = try XCTUnwrap(document["period"] as? [String: Any])
        XCTAssertEqual(period["selection"] as? String, "retained")
        XCTAssertTrue(period["startInclusiveUnixSeconds"] is NSNull)
        XCTAssertEqual(period["lowerBoundKind"] as? String,
                       "unreportedFiniteFilterSentinelNotCoverageStart")
        XCTAssertEqual(period["endExclusiveUnixSeconds"] as? Double,
                       now.timeIntervalSince1970)
    }

    func testMismatchedPeriodStateAndNonfiniteTimesRefuseExport() throws {
        let value = try result([])
        let good = LocalStatisticsJSONExport.Input(displayState: .empty,
                                                    selection: .last7Days, result: value)
        XCTAssertThrowsError(try LocalStatisticsJSONExport.encode(
            .init(displayState: .empty, selection: .last24Hours, result: value)))
        XCTAssertThrowsError(try LocalStatisticsJSONExport.encode(
            .init(displayState: .populated, selection: .last7Days, result: value)))
        XCTAssertThrowsError(try LocalStatisticsJSONExport.encode(good,
            generatedAt: Date(timeIntervalSince1970: .nan)))
        XCTAssertThrowsError(try LocalStatisticsJSONExport.encode(
            .init(displayState: .partial, selection: .last7Days, result: value)))
        let impossibleCompleteEmpty = try result([], reader: .complete)
        XCTAssertThrowsError(try LocalStatisticsJSONExport.encode(
            .init(displayState: .empty, selection: .last7Days,
                  result: impossibleCompleteEmpty)))
    }

    func testEncodingIsByteStableAndUsesNumericUnixTime() throws {
        let value = try result([], reader: .validEmpty)
        let input = LocalStatisticsJSONExport.Input(displayState: .empty,
                                                     selection: .last7Days, result: value)
        let first = try LocalStatisticsJSONExport.encode(input, generatedAt: now)
        // The encoder uses fixed keys and numeric Unix time; this test proves
        // repeatability for an identical in-process input, not cross-locale QA.
        let second = try LocalStatisticsJSONExport.encode(input, generatedAt: now)
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.contains("1000000.125"))
    }
}
