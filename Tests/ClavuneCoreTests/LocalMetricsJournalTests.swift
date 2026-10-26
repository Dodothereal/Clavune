import Foundation
import XCTest
@testable import ClavuneCore

final class LocalMetricsJournalTests: XCTestCase {
    private func addSyntheticReadACL(_ url: URL) throws {
        let command = Process()
        command.executableURL = URL(fileURLWithPath: "/bin/chmod")
        command.arguments = ["+a", "everyone allow read", url.path]
        try command.run()
        command.waitUntilExit()
        guard command.terminationStatus == 0 else { throw CocoaError(.fileWriteNoPermission) }
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clavune-metrics-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return url
    }

    private func events(in directory: URL) throws -> [(URL, LocalMetricsEvent)] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("events-") && $0.pathExtension == "jsonl" }
        return try files.flatMap { file in
            try Data(contentsOf: file).split(separator: 0x0A, omittingEmptySubsequences: true).map {
                (file, try JSONDecoder().decode(LocalMetricsEvent.self, from: Data($0)))
            }
        }
    }

    private func seededOldSegment(in root: URL) async throws -> (url: URL, bytes: Data) {
        let first = LocalMetricsJournal(directoryURL: root)
        first.record(LocalMetricsEvent(sessionID: UUID(), kind: .sessionStarted, source: .microphone))
        let synced = await first.synchronize(); XCTAssertTrue(synced)
        let closed = await first.close(); XCTAssertTrue(closed)
        let url = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil).first {
                $0.lastPathComponent.hasPrefix("events-") && $0.pathExtension == "jsonl"
            })
        return (url, try Data(contentsOf: url))
    }

    func testWordRateUsesAudioDurationAndContentFreeEncoding() throws {
        let id = UUID()
        let event = LocalMetricsEvent(sessionID: id, kind: .transcriptionCompleted, source: .microphone,
            sourceSampleRateHz: 44_100, processingSampleRateHz: 16_000,
            audioDurationSeconds: 30, recognizedWordCount: 45,
            wordsPerMinute: LocalMetricsEvent.wordsPerMinute(words: 45, audioSeconds: 30))
        XCTAssertEqual(LocalMetricsEvent.wordCount("Morgen, Zürich — 42 Wörter."), 4)
        XCTAssertEqual(event.wordsPerMinute, 90)
        XCTAssertEqual(event.sourceSampleRateHz, 44_100)
        XCTAssertEqual(event.processingSampleRateHz, 16_000)
        XCTAssertNil(event.modelWarm)
        XCTAssertNil(LocalMetricsEvent.wordsPerMinute(words: 4, audioSeconds: 0))
        let encoded = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        XCTAssertFalse(encoded.contains("transcript text"))
        XCTAssertFalse(encoded.contains("/synthetic-fixture/"))
        XCTAssertFalse(encoded.contains("clipboard contents"))
        XCTAssertFalse(encoded.contains("filePath"))
    }

    func testWordCountPreservesLegacyUnicodeAndTokenBoundaries() {
        // Keep the previous implementation only as a small-input semantic oracle.
        // Never run its token-array allocations on the 4 MiB stress cases below.
        func legacyCount(_ text: String) -> Int {
            text.split(whereSeparator: \.isWhitespace)
                .filter { token in token.contains(where: { $0.isLetter || $0.isNumber }) }.count
        }
        let examples = [
            "", " ", "\t\n  ", "!!! -- _", "Morgen, Zürich — 42 Wörter.",
            "é e\u{0301} 中 ١ Ⅳ", "👩‍💻 👋🏽 !", "!a! _42_", "a\u{00A0}b", "a\n\nb"
        ]
        for example in examples {
            XCTAssertEqual(LocalMetricsEvent.wordCount(example), legacyCount(example))
        }
        let characters: [Character] = ["a", "é", "e\u{0301}", "中", "١", "Ⅳ",
                                       "👩‍💻", "!", "_", " ", "\t", "\n", "\u{00A0}"]
        for first in characters {
            for second in characters {
                for third in characters {
                    let text = String([first, second, third])
                    XCTAssertEqual(LocalMetricsEvent.wordCount(text), legacyCount(text))
                }
            }
        }
    }

    func testWordCountHandlesFourMiBHighAndLowTokenDensity() {
        let maximum = TranscriptFileStore.maximumBytes
        let alternating = String(repeating: "a ", count: maximum / 2)
        XCTAssertEqual(alternating.utf8.count, maximum)
        XCTAssertEqual(LocalMetricsEvent.wordCount(alternating), maximum / 2)

        let singleWord = String(repeating: "a", count: maximum)
        XCTAssertEqual(singleWord.utf8.count, maximum)
        XCTAssertEqual(LocalMetricsEvent.wordCount(singleWord), 1)
    }

    func testAppendIsDurableDeduplicatedAndPrivate() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = LocalMetricsJournal(directoryURL: root)
        let session = UUID()
        let started = LocalMetricsEvent(sessionID: session, kind: .sessionStarted, source: .audioFile,
            requestedLanguage: "de", modelFileName: "candidate.bin", modelSHA256: String(repeating: "a", count: 64))
        let completed = LocalMetricsEvent(sessionID: session, kind: .transcriptionCompleted, source: .audioFile,
            requestedLanguage: "de", detectedLanguageID: 1, modelFileName: "candidate.bin",
            audioFrames16k: 32_000, audioDurationSeconds: 2, recognizedWordCount: 6,
            wordsPerMinute: 180, decodeSeconds: 0.4, endToEndSeconds: 0.8)
        journal.record(started); journal.record(completed); journal.record(completed)
        let synced = await journal.synchronize()
        XCTAssertTrue(synced)
        let actual = try events(in: root).map(\.1)
        XCTAssertEqual(actual.map(\.kind), [.sessionStarted, .transcriptionCompleted])
        XCTAssertEqual(actual.map(\.eventID), [started.eventID, completed.eventID])
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("events-") && $0.pathExtension == "jsonl" }
        XCTAssertEqual(files.count, 1)
        let attrs = try FileManager.default.attributesOfItem(atPath: files[0].path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let text = try String(contentsOf: files[0], encoding: .utf8)
        XCTAssertFalse(text.contains("rawTranscript")); XCTAssertFalse(text.contains("editedText"))
        XCTAssertFalse(text.contains("/synthetic-fixture/")); XCTAssertFalse(text.contains("clipboard"))
        let closed = await journal.close(); XCTAssertTrue(closed)
    }

    func testExtendedACLPreventsJournalWritesAndRecovery() async throws {
        let exposedDirectory = try directory()
        defer { try? FileManager.default.removeItem(at: exposedDirectory) }
        try addSyntheticReadACL(exposedDirectory)
        let blocked = LocalMetricsJournal(directoryURL: exposedDirectory)
        blocked.record(LocalMetricsEvent(sessionID: UUID(), kind: .sessionStarted,
                                         source: .microphone))
        let blockedSynced = await blocked.synchronize()
        XCTAssertFalse(blockedSynced)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(
            at: exposedDirectory, includingPropertiesForKeys: nil).isEmpty)

        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let first = LocalMetricsJournal(directoryURL: root)
        first.record(LocalMetricsEvent(sessionID: UUID(), kind: .sessionStarted,
                                       source: .microphone))
        let firstSynced = await first.synchronize()
        XCTAssertTrue(firstSynced)
        let firstClosed = await first.close()
        XCTAssertTrue(firstClosed)
        let prior = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil).first {
                $0.lastPathComponent.hasPrefix("events-") && $0.pathExtension == "jsonl"
            })
        let oldBytes = try Data(contentsOf: prior)
        try addSyntheticReadACL(prior)
        let next = LocalMetricsJournal(directoryURL: root)
        next.record(LocalMetricsEvent(sessionID: UUID(), kind: .sessionStarted,
                                      source: .audioFile))
        let nextSynced = await next.synchronize()
        XCTAssertFalse(nextSynced)
        XCTAssertEqual(try Data(contentsOf: prior), oldBytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil).filter {
                $0.lastPathComponent.hasPrefix("events-") && $0.pathExtension == "jsonl"
            }.count, 1)
    }

    func testNextLaunchMarksOnlyRecoverableUnfinishedSessionsInterrupted() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let abandoned = UUID(), current = UUID()
        let first = LocalMetricsJournal(directoryURL: root)
        first.record(LocalMetricsEvent(sessionID: abandoned, kind: .sessionStarted,
                                      source: .microphone, requestedLanguage: "en"))
        let firstSynced = await first.synchronize(); XCTAssertTrue(firstSynced)
        let firstClosed = await first.close(); XCTAssertTrue(firstClosed)

        let second = LocalMetricsJournal(directoryURL: root)
        second.record(LocalMetricsEvent(sessionID: current, kind: .sessionStarted, source: .microphone))
        let secondSynced = await second.synchronize(); XCTAssertTrue(secondSynced)
        let secondClosed = await second.close(); XCTAssertTrue(secondClosed)
        let recovered = try events(in: root).map(\.1)
        XCTAssertEqual(recovered.filter { $0.kind == .sessionInterrupted }.map(\.sessionID), [abandoned])

        let third = LocalMetricsJournal(directoryURL: root)
        third.record(LocalMetricsEvent(sessionID: UUID(), kind: .reviewAction, source: .transcriptFile,
                                       reviewAction: .open, actionSucceeded: true))
        let thirdSynced = await third.synchronize(); XCTAssertTrue(thirdSynced)
        let interruptedIDs = Set(try events(in: root).filter { $0.1.kind == .sessionInterrupted }.map { $0.1.sessionID })
        XCTAssertEqual(interruptedIDs, Set([abandoned, current]))
        let thirdClosed = await third.close(); XCTAssertTrue(thirdClosed)
    }

    func testTruncatedJournalIsPreservedAndNotAppendedOver() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let first = LocalMetricsJournal(directoryURL: root)
        first.record(LocalMetricsEvent(sessionID: UUID(), kind: .sessionStarted, source: .audioFile))
        let firstSynced = await first.synchronize(); XCTAssertTrue(firstSynced)
        let firstClosed = await first.close(); XCTAssertTrue(firstClosed)
        let oldFile = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("events-") && $0.pathExtension == "jsonl" })
        let original = try Data(contentsOf: oldFile)
        let brokenTail = Data("{\"schemaVersion\":".utf8)
        let handle = try FileHandle(forWritingTo: oldFile); try handle.seekToEnd(); try handle.write(contentsOf: brokenTail); try handle.close()
        let damaged = try Data(contentsOf: oldFile)

        let next = LocalMetricsJournal(directoryURL: root)
        next.record(LocalMetricsEvent(sessionID: UUID(), kind: .reviewAction, source: .transcriptFile,
                                     reviewAction: .open, actionSucceeded: true))
        let nextSynced = await next.synchronize(); XCTAssertTrue(nextSynced)
        let nextClosed = await next.close(); XCTAssertTrue(nextClosed)
        XCTAssertEqual(try Data(contentsOf: oldFile), damaged)
        XCTAssertTrue(damaged.starts(with: original))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("events-") && $0.pathExtension == "jsonl" }.count, 2)
    }

    func testRecoveryRejectsReplacementAfterOpeningCheckedOldSegment() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let old = try await seededOldSegment(in: root)
        let backup = root.appendingPathComponent("original-segment.backup")
        let replacement = root.appendingPathComponent("synthetic-replacement.jsonl")
        let other = LocalMetricsEvent(sessionID: UUID(), kind: .reviewAction,
            source: .transcriptFile, reviewAction: .open, actionSucceeded: true)
        var replacementBytes = try JSONEncoder().encode(other); replacementBytes.append(0x0A)
        try replacementBytes.write(to: replacement, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: replacement.path)

        let next = LocalMetricsJournal(directoryURL: root, afterValidatingOldSegment: { url in
            try? FileManager.default.moveItem(at: url, to: backup)
            try? FileManager.default.moveItem(at: replacement, to: url)
        })
        next.record(LocalMetricsEvent(sessionID: UUID(), kind: .sessionStarted, source: .audioFile))
        let synced = await next.synchronize()
        XCTAssertFalse(synced, "Recovery must reject a different inode at the original name")
        XCTAssertEqual(try Data(contentsOf: backup), old.bytes)
        XCTAssertEqual(try Data(contentsOf: old.url), replacementBytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("events-") && $0.pathExtension == "jsonl" }.count, 1)
    }

    func testRecoveryRejectsGrowthOfOpenedOldSegment() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let old = try await seededOldSegment(in: root)
        let next = LocalMetricsJournal(directoryURL: root, afterValidatingOldSegment: { url in
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data([0x20]))
                try? handle.close()
            }
        })
        next.record(LocalMetricsEvent(sessionID: UUID(), kind: .sessionStarted, source: .audioFile))
        let synced = await next.synchronize()
        XCTAssertFalse(synced, "Recovery must reject a segment changed after validation")
        var grown = old.bytes; grown.append(0x20)
        XCTAssertEqual(try Data(contentsOf: old.url), grown)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("events-") && $0.pathExtension == "jsonl" }.count, 1)
    }

    func testCapacityFailureKeepsExistingHistory() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let first = LocalMetricsJournal(directoryURL: root)
        first.record(LocalMetricsEvent(sessionID: UUID(), kind: .sessionStarted, source: .microphone))
        let firstSynced = await first.synchronize(); XCTAssertTrue(firstSynced)
        let firstClosed = await first.close(); XCTAssertTrue(firstClosed)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("events-") && $0.pathExtension == "jsonl" })
        let before = try Data(contentsOf: file)
        let capped = LocalMetricsJournal(directoryURL: root, limits: .init(totalBytes: before.count - 1))
        capped.record(LocalMetricsEvent(sessionID: UUID(), kind: .reviewAction, source: .transcriptFile,
                                       reviewAction: .open, actionSucceeded: true))
        let cappedSynced = await capped.synchronize(); XCTAssertFalse(cappedSynced)
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testInvalidFieldsAreRejectedWithoutBreakingApplication() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = LocalMetricsJournal(directoryURL: root)
        journal.record(LocalMetricsEvent(sessionID: UUID(), kind: .transcriptionCompleted, source: .microphone,
                                         decodeSeconds: .nan))
        journal.record(LocalMetricsEvent(sessionID: UUID(), kind: .sessionFailed, source: .microphone,
                                         failureCode: "/synthetic-fixture/private/diagnostic.log"))
        journal.record(LocalMetricsEvent(sessionID: UUID(), kind: .sessionStarted, source: .audioFile,
                                         modelFileName: "../private.wav"))
        let invalidSynced = await journal.synchronize(); XCTAssertTrue(invalidSynced)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).isEmpty)
        let invalidClosed = await journal.close(); XCTAssertTrue(invalidClosed)
    }

    func testWriterLockPreventsConcurrentInstancesFromExceedingSharedQuota() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        let first = LocalMetricsJournal(directoryURL: root)
        first.record(LocalMetricsEvent(sessionID: sessionID, kind: .sessionStarted, source: .microphone))
        let firstSynced = await first.synchronize(); XCTAssertTrue(firstSynced)

        let second = LocalMetricsJournal(directoryURL: root)
        second.record(LocalMetricsEvent(sessionID: UUID(), kind: .reviewAction, source: .transcriptFile,
                                        reviewAction: .open, actionSucceeded: true))
        let secondSynced = await second.synchronize(); XCTAssertFalse(secondSynced)
        let secondClosed = await second.close(); XCTAssertFalse(secondClosed)
        XCTAssertEqual(try events(in: root).count, 1)

        first.record(LocalMetricsEvent(sessionID: sessionID, kind: .sessionFailed, source: .microphone,
                                       failureCode: "inferenceFailed"))
        let firstStillSynced = await first.synchronize(); XCTAssertTrue(firstStillSynced)
        let firstClosed = await first.close(); XCTAssertTrue(firstClosed)
        XCTAssertEqual(try events(in: root).count, 2)
    }

    func testInvalidDecodedRecordCannotSuppressInterruptedRecovery() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        let invalidTerminal = LocalMetricsEvent(sessionID: sessionID, kind: .sessionFailed,
            source: .microphone, audioFrames16k: -1, failureCode: "inferenceFailed")
        let start = LocalMetricsEvent(sessionID: sessionID, kind: .sessionStarted, source: .microphone)
        var invalid = try JSONEncoder().encode(invalidTerminal); invalid.append(0x0A)
        var validStart = try JSONEncoder().encode(start); validStart.append(0x0A)
        let badURL = root.appendingPathComponent("events-a-invalid.jsonl")
        let startURL = root.appendingPathComponent("events-b-start.jsonl")
        try invalid.write(to: badURL, options: .atomic)
        try validStart.write(to: startURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: badURL.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: startURL.path)

        let journal = LocalMetricsJournal(directoryURL: root)
        journal.record(LocalMetricsEvent(sessionID: UUID(), kind: .reviewAction, source: .transcriptFile,
                                         reviewAction: .open, actionSucceeded: true))
        let synced = await journal.synchronize(); XCTAssertTrue(synced)
        let all = try events(in: root).map(\.1)
        XCTAssertEqual(all.filter { $0.sessionID == sessionID && $0.kind == .sessionInterrupted }.count, 1)
        let closed = await journal.close(); XCTAssertTrue(closed)
    }
}
