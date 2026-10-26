import ClavuneCore
import Foundation

/// Fixed, content-free example events for the isolated visual QA app. No
/// journal, user file, recorder, model or network boundary is constructed.
enum LocalStatisticsSyntheticPreview {
    static let referenceTime = Date(timeIntervalSince1970: 1_792_756_800) // 2026-10-23 12:00 UTC

    private static func identity(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", value))!
    }

    private static let exampleEvents: [LocalMetricsEvent] = {
        let now = referenceTime
        let microphone = identity(1), imported = identity(2), document = identity(3), old = identity(4)
        return [
            LocalMetricsEvent(eventID: identity(101), sessionID: microphone,
                timestamp: now.addingTimeInterval(-7_200), kind: .sessionStarted,
                source: .microphone, requestedLanguage: "auto"),
            LocalMetricsEvent(eventID: identity(102), sessionID: microphone,
                timestamp: now.addingTimeInterval(-7_140), kind: .transcriptionCompleted,
                source: .microphone, requestedLanguage: "auto", detectedLanguageID: 7,
                audioDurationSeconds: 60, recognizedWordCount: 90, wordsPerMinute: 90,
                decodeSeconds: 2.4, endToEndSeconds: 4.2),
            LocalMetricsEvent(eventID: identity(103), sessionID: microphone,
                timestamp: now.addingTimeInterval(-7_130), kind: .reviewAction,
                source: .microphone, reviewAction: .copy, actionSucceeded: true),
            LocalMetricsEvent(eventID: identity(104), sessionID: imported,
                timestamp: now.addingTimeInterval(-2 * 86_400 - 90), kind: .sessionStarted,
                source: .audioFile, requestedLanguage: "de"),
            LocalMetricsEvent(eventID: identity(105), sessionID: imported,
                timestamp: now.addingTimeInterval(-2 * 86_400), kind: .transcriptionCompleted,
                source: .audioFile, requestedLanguage: "de",
                audioDurationSeconds: 60, recognizedWordCount: 40, wordsPerMinute: 40,
                audioPreparationSeconds: 1.2, decodeSeconds: 3.1, endToEndSeconds: 6.5),
            LocalMetricsEvent(eventID: identity(106), sessionID: document,
                timestamp: now.addingTimeInterval(-10 * 86_400), kind: .reviewAction,
                source: .transcriptFile, reviewAction: .open, actionSucceeded: true),
            LocalMetricsEvent(eventID: identity(107), sessionID: old,
                timestamp: now.addingTimeInterval(-45 * 86_400 - 12), kind: .sessionStarted,
                source: .microphone, requestedLanguage: "en"),
            LocalMetricsEvent(eventID: identity(108), sessionID: old,
                timestamp: now.addingTimeInterval(-45 * 86_400), kind: .sessionFailed,
                source: .microphone, requestedLanguage: "en")
        ]
    }()

    static func load(_ period: LocalStatisticsSummaryBuilder.Period) async throws -> LocalStatisticsLoadResult {
        let report = try LocalStatisticsSummaryBuilder.build(events: exampleEvents, period: period)
        return LocalStatisticsLoadResult(report: report, diagnostics: LocalStatisticsReadDiagnostics(),
                                         loadedAt: referenceTime)
    }
}
