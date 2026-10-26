import Foundation
import XCTest
@testable import ClavuneCore

final class LocalStatisticsSummaryTests: XCTestCase {
    private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }
    private func window(_ start: TimeInterval = 100, _ end: TimeInterval = 200) throws
        -> LocalStatisticsSummaryBuilder.Period {
        try .init(start: date(start), endExclusive: date(end))
    }
    private func event(_ session: UUID, _ seconds: TimeInterval, _ kind: LocalMetricsEvent.Kind,
                       _ source: LocalMetricsEvent.Source, language: String? = nil,
                       detected: Int? = nil, words: Int? = nil, audio: Double? = nil,
                       rate: Double? = nil, decode: Double? = nil, total: Double? = nil,
                       review: LocalMetricsEvent.ReviewAction? = nil, success: Bool? = nil)
        -> LocalMetricsEvent {
        LocalMetricsEvent(sessionID: session, timestamp: date(seconds), kind: kind, source: source,
                          requestedLanguage: language, detectedLanguageID: detected,
                          audioDurationSeconds: audio, recognizedWordCount: words,
                          wordsPerMinute: rate, decodeSeconds: decode, endToEndSeconds: total,
                          reviewAction: review, actionSucceeded: success)
    }

    func testOutcomesStaySeparateAndMissingMeasurementsAreNotZero() throws {
        let completed = UUID(), failed = UUID(), cancelled = UUID(), interrupted = UUID(), open = UUID()
        let events = [
            event(completed, 101, .sessionStarted, .microphone, language: "auto"),
            event(completed, 120, .transcriptionCompleted, .microphone, language: "auto",
                  detected: 7, words: 0, audio: 10, rate: 0, decode: 1, total: 4),
            event(failed, 102, .sessionStarted, .microphone, language: "de"),
            event(failed, 121, .sessionFailed, .microphone, language: "de", total: 8),
            event(cancelled, 103, .sessionStarted, .audioFile, language: "en"),
            event(cancelled, 122, .sessionCancelled, .audioFile, language: "en", total: 2),
            event(interrupted, 104, .sessionStarted, .audioFile, language: "auto"),
            event(interrupted, 123, .sessionInterrupted, .audioFile, language: "auto"),
            event(open, 105, .sessionStarted, .audioFile, language: "en")
        ]
        let report = try LocalStatisticsSummaryBuilder.build(events: events, period: window())
        XCTAssertEqual(report.microphone.started, 2)
        XCTAssertEqual(report.microphone.completed, 1)
        XCTAssertEqual(report.microphone.failed, 1)
        XCTAssertEqual(report.audioFile.cancelled, 1)
        XCTAssertEqual(report.audioFile.endToEndSecondsOnCompleted.observed, 0)
        XCTAssertNil(report.audioFile.endToEndSecondsOnCompleted.sum)
        XCTAssertEqual(report.audioFile.interrupted, 1)
        XCTAssertEqual(report.audioFile.incompleteAtPeriodEnd, 1)
        XCTAssertEqual(report.audioFile.completed, 0)
        XCTAssertEqual(report.microphone.recognizedWordsOnCompleted.observed, 1)
        XCTAssertEqual(report.microphone.recognizedWordsOnCompleted.sum, 0)
        XCTAssertEqual(report.microphone.audioWordRateOnCompleted.sum, 0)
        XCTAssertEqual(report.microphone.requestedLanguageOnCompleted.autoDetectedRawIDs, [7: 1])
        XCTAssertNil(report.audioFile.recognizedWordsOnCompleted.sum)
        XCTAssertNil(report.audioFile.endToEndSecondsOnCompleted.mean)
        XCTAssertTrue(report.historicalCoverageUnknown)
    }

    func testMeanWordRateUsesObservedSessionRatesRatherThanPooledAudio() throws {
        let short = UUID(), long = UUID(), unmeasured = UUID()
        let report = try LocalStatisticsSummaryBuilder.build(events: [
            event(short, 101, .sessionStarted, .microphone),
            event(short, 110, .transcriptionCompleted, .microphone,
                  words: 60, audio: 60, rate: 60),
            event(long, 102, .sessionStarted, .microphone),
            event(long, 111, .transcriptionCompleted, .microphone,
                  words: 60, audio: 600, rate: 6),
            event(unmeasured, 103, .sessionStarted, .microphone),
            event(unmeasured, 112, .transcriptionCompleted, .microphone,
                  words: 0, audio: nil, rate: nil)
        ], period: window())
        XCTAssertEqual(report.microphone.completed, 3)
        XCTAssertEqual(report.microphone.recognizedWordsOnCompleted.sum, 120)
        XCTAssertEqual(report.microphone.recognizedWordsOnCompleted.observed, 3,
                       "An observed zero word count is not an unknown measurement")
        XCTAssertEqual(report.microphone.audioSecondsOnCompleted.sum, 660)
        XCTAssertEqual(report.microphone.audioWordRateOnCompleted.observed, 2)
        XCTAssertEqual(report.microphone.audioWordRateOnCompleted.unknown, 1)
        XCTAssertEqual(report.microphone.audioWordRateOnCompleted.sum, 66)
        XCTAssertEqual(report.microphone.audioWordRateOnCompleted.mean, 33)
        XCTAssertNotEqual(try XCTUnwrap(report.microphone.audioWordRateOnCompleted.mean),
                          Double(120) * 60 / 660, "The UI labels a per-session arithmetic mean")
    }

    func testDuplicateEventsAndConflictingTerminalsCannotInflateCompletedCount() throws {
        let good = UUID(), conflict = UUID()
        let goodStart = event(good, 101, .sessionStarted, .microphone)
        let goodEnd = event(good, 111, .transcriptionCompleted, .microphone, words: 5, audio: 5,
                            rate: 60)
        let badStart = event(conflict, 102, .sessionStarted, .audioFile)
        let badEnd = event(conflict, 112, .transcriptionCompleted, .audioFile, words: 10)
        let alternate = event(conflict, 113, .sessionCancelled, .audioFile)
        let report = try LocalStatisticsSummaryBuilder.build(
            events: [goodStart, goodEnd, goodEnd, badStart, badEnd, alternate], period: window())
        XCTAssertEqual(report.duplicateEventRecords, 1)
        XCTAssertEqual(report.microphone.completed, 1)
        XCTAssertEqual(report.audioFile.completed, 0)
        XCTAssertEqual(report.audioFile.cancelled, 0)
        XCTAssertEqual(report.audioFile.ambiguous, 1)
        XCTAssertEqual(report.microphone.recognizedWordsOnCompleted.sum, 5)

        let sameIdentityDifferentPayload = LocalMetricsEvent(eventID: goodEnd.eventID,
            sessionID: good, timestamp: date(111), kind: .sessionFailed, source: .microphone)
        let poisoned = try LocalStatisticsSummaryBuilder.build(
            events: [goodStart, goodEnd, sameIdentityDifferentPayload], period: window())
        XCTAssertEqual(poisoned.conflictingEventIDGroups, 1)
        XCTAssertEqual(poisoned.microphone.completed, 0)
        XCTAssertEqual(poisoned.microphone.started, 1)
        XCTAssertEqual(poisoned.microphone.incompleteAtPeriodEnd, 0)
        XCTAssertEqual(poisoned.microphone.ambiguous, 1)
    }

    func testReversedTerminalBeforePeriodMarksInPeriodStartAmbiguous() throws {
        let session = UUID()
        let report = try LocalStatisticsSummaryBuilder.build(events: [
            event(session, 101, .sessionStarted, .microphone),
            event(session, 90, .transcriptionCompleted, .microphone, words: 3)
        ], period: window())
        XCTAssertEqual(report.microphone.started, 1)
        XCTAssertEqual(report.microphone.completed, 0)
        XCTAssertEqual(report.microphone.incompleteAtPeriodEnd, 0)
        XCTAssertEqual(report.microphone.ambiguous, 1)
    }

    func testReviewAttemptsAreNotTranscriptionSessionsOrIndependentSavedUsers() throws {
        let session = UUID(), document = UUID(), orphan = UUID()
        let start = event(session, 101, .sessionStarted, .microphone)
        let finish = event(session, 111, .transcriptionCompleted, .microphone, words: 4)
        let copy1 = event(session, 120, .reviewAction, .microphone, review: .copy, success: true)
        let copy2 = event(session, 121, .reviewAction, .microphone, review: .copy, success: true)
        let save = event(session, 122, .reviewAction, .microphone, review: .save, success: false)
        let documentOpen = event(document, 123, .reviewAction, .transcriptFile, review: .open, success: true)
        let phantom = event(orphan, 124, .reviewAction, .audioFile, review: .save, success: true)
        let report = try LocalStatisticsSummaryBuilder.build(
            events: [start, finish, copy1, copy1, copy2, save, documentOpen, phantom], period: window())
        XCTAssertEqual(report.microphone.completed, 1)
        XCTAssertEqual(report.microphone.reviews.copy.attempts, 2)
        XCTAssertEqual(report.microphone.reviews.copy.succeeded, 2)
        XCTAssertEqual(report.microphone.reviews.copy.distinctSuccessfulSessions, 1)
        XCTAssertEqual(report.microphone.reviews.save.notSucceeded, 1)
        XCTAssertEqual(report.transcriptFile.reviews.open.succeeded, 1)
        XCTAssertNil(report.transcriptFile.reviews.open.distinctSuccessfulSessions)
        XCTAssertEqual(report.transcriptFile.completed, 0)
        XCTAssertEqual(report.orphanReviewEvents, 1)
    }

    func testPeriodEdgesAndRequestedLanguageDoNotForgeDetection() throws {
        let crossed = UUID(), later = UUID(), fixed = UUID(), missing = UUID()
        let events = [
            event(crossed, 90, .sessionStarted, .audioFile, language: "en"),
            event(crossed, 100, .transcriptionCompleted, .audioFile, language: "en",
                  detected: 0, words: 2, audio: 10, rate: 12),
            event(later, 190, .sessionStarted, .microphone, language: "auto"),
            event(later, 200, .transcriptionCompleted, .microphone, language: "auto", detected: 1),
            event(fixed, 110, .sessionStarted, .microphone, language: "de"),
            event(fixed, 120, .transcriptionCompleted, .microphone, language: "de", detected: 1),
            event(missing, 130, .sessionStarted, .microphone, language: "auto"),
            event(missing, 140, .transcriptionCompleted, .microphone, language: "auto",
                  words: nil, audio: nil, rate: nil)
        ]
        let report = try LocalStatisticsSummaryBuilder.build(events: events, period: window())
        XCTAssertEqual(report.audioFile.started, 0)
        XCTAssertEqual(report.audioFile.completed, 1)
        XCTAssertEqual(report.microphone.incompleteAtPeriodEnd, 1)
        XCTAssertEqual(report.microphone.started, 3)
        XCTAssertEqual(report.microphone.completed, 2)
        XCTAssertEqual(report.microphone.recognizedWordsOnCompleted.unknown, 2)
        XCTAssertEqual(report.microphone.audioWordRateOnCompleted.unknown, 2)
        XCTAssertEqual(report.microphone.requestedLanguageOnCompleted.german, 1)
        XCTAssertEqual(report.microphone.requestedLanguageOnCompleted.auto, 1)
        XCTAssertTrue(report.microphone.requestedLanguageOnCompleted.autoDetectedRawIDs.isEmpty)
        XCTAssertEqual(report.microphone.requestedLanguageOnCompleted.autoDetectionUnknown, 1)
        XCTAssertEqual(report.audioFile.requestedLanguageOnCompleted.english, 1)
        XCTAssertTrue(report.audioFile.requestedLanguageOnCompleted.autoDetectedRawIDs.isEmpty)
    }

    func testRejectsUnboundedInputAndInvalidWindow() throws {
        XCTAssertThrowsError(try window(100, 100))
        let sample = event(UUID(), 101, .sessionStarted, .microphone)
        XCTAssertThrowsError(try LocalStatisticsSummaryBuilder.build(
            events: Array(repeating: sample, count: LocalStatisticsSummaryBuilder.maximumInputEvents + 1),
            period: window()))
    }

    func testWriterInvalidRecordsNeverBecomeCompletedStatistics() throws {
        let negative = UUID(), privateName = UUID(), badRate = UUID()
        let invalidWord = event(negative, 111, .transcriptionCompleted, .microphone,
                                words: -5, audio: 10)
        let invalidName = LocalMetricsEvent(sessionID: privateName, timestamp: date(112),
            kind: .transcriptionCompleted, source: .audioFile,
            modelFileName: "/synthetic/private/transcript.txt", recognizedWordCount: 10)
        let report = try LocalStatisticsSummaryBuilder.build(events: [
            event(negative, 101, .sessionStarted, .microphone), invalidWord,
            event(privateName, 102, .sessionStarted, .audioFile), invalidName,
            event(badRate, 103, .sessionStarted, .microphone),
            event(badRate, 113, .transcriptionCompleted, .microphone,
                  words: 10, audio: 10, rate: 600)
        ], period: window())
        XCTAssertEqual(report.invalidRecordEvents, 2)
        XCTAssertEqual(report.microphone.completed, 1)
        XCTAssertEqual(report.microphone.audioWordRateOnCompleted.observed, 0)
        XCTAssertEqual(report.microphone.audioWordRateOnCompleted.unknown, 1)
        XCTAssertEqual(report.microphone.recognizedWordsOnCompleted.sum, 10)
        XCTAssertEqual(report.microphone.incompleteAtPeriodEnd, 0)
        XCTAssertEqual(report.microphone.ambiguous, 1)
        XCTAssertEqual(report.audioFile.completed, 0)
        XCTAssertEqual(report.audioFile.incompleteAtPeriodEnd, 0)
        XCTAssertEqual(report.audioFile.ambiguous, 1)
    }
}
