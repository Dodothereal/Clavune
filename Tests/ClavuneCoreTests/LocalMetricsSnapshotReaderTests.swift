import Darwin
import Foundation
import XCTest
@testable import ClavuneCore

/// Synthetic-directory tests only. Never open the user's Application Support journal.
final class LocalMetricsSnapshotReaderTests: XCTestCase {
    private func addSyntheticReadACL(_ url: URL) throws {
        let command = Process()
        command.executableURL = URL(fileURLWithPath: "/bin/chmod")
        command.arguments = ["+a", "everyone allow read", url.path]
        try command.run()
        command.waitUntilExit()
        guard command.terminationStatus == 0 else { throw CocoaError(.fileWriteNoPermission) }
    }

    private func canonicalTemporaryDirectory() throws -> URL {
        // NSURL.resolvingSymlinksInPath can rewrite /private/var to /var on Mac;
        // realpath is required because the reader deliberately rejects every
        // intermediate symlink, including the ordinary /var -> /private/var.
        let source = FileManager.default.temporaryDirectory.path
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        let succeeded = source.withCString { path in
            resolved.withUnsafeMutableBufferPointer { buffer in
                Darwin.realpath(path, buffer.baseAddress) != nil
            }
        }
        guard succeeded else {
            throw CocoaError(.fileReadUnknown)
        }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    private func directory() throws -> URL {
        let root = try canonicalTemporaryDirectory()
            .appendingPathComponent("clavune-snapshot-fixture-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        return root
    }

    private func window() throws -> LocalStatisticsSummaryBuilder.Period {
        try .init(start: Date(timeIntervalSince1970: 100),
                  endExclusive: Date(timeIntervalSince1970: 200))
    }

    private func event(_ session: UUID, _ second: TimeInterval,
                       _ kind: LocalMetricsEvent.Kind,
                       _ source: LocalMetricsEvent.Source,
                       eventID: UUID = UUID(), words: Int? = nil,
                       modelFileName: String? = nil) -> LocalMetricsEvent {
        LocalMetricsEvent(eventID: eventID, sessionID: session,
            timestamp: Date(timeIntervalSince1970: second), kind: kind,
            source: source, modelFileName: modelFileName,
            recognizedWordCount: words)
    }

    private func jsonLine(_ event: LocalMetricsEvent) throws -> Data {
        var bytes = try JSONEncoder().encode(event)
        bytes.append(0x0A)
        return bytes
    }

    private func write(_ bytes: Data, to root: URL, name: String = "events-synthetic.jsonl") throws -> URL {
        let file = root.appendingPathComponent(name)
        try bytes.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file
    }

    func testSecureEmptyDirectoryIsValidEmptyButNotKnownLifetimeZero() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let result = LocalMetricsSnapshotReader.readSummary(directoryURL: root, period: try window())
        XCTAssertEqual(result.diagnostics.state, .validEmpty)
        XCTAssertNotNil(result.summary)
        XCTAssertEqual(result.summary?.microphone.completed, 0)
        XCTAssertTrue(result.diagnostics.historicalCoverageUnknown)
        XCTAssertTrue(result.summary?.historicalCoverageUnknown == true)
    }

    func testMissingFreshJournalIsValidEmptyNotLifetimeZero() throws {
        let root = try canonicalTemporaryDirectory()
            .appendingPathComponent("clavune-never-created-\(UUID())", isDirectory: true)
        let result = LocalMetricsSnapshotReader.readSummary(directoryURL: root, period: try window())
        XCTAssertEqual(result.diagnostics.state, .validEmpty)
        XCTAssertEqual(result.diagnostics.segmentCount, 0)
        XCTAssertEqual(result.summary?.microphone.started, 0)
        XCTAssertTrue(result.diagnostics.historicalCoverageUnknown)
    }

    func testCrossWindowStartAndPrivateModelNameStayInternal() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = UUID(), canary = "SYNTHETIC_PRIVATE_MODEL_BASENAME_CANARY"
        var bytes = try jsonLine(event(session, 90, .sessionStarted, .audioFile,
                                       modelFileName: canary))
        bytes.append(try jsonLine(event(session, 100, .transcriptionCompleted, .audioFile,
                                        words: 3, modelFileName: canary)))
        _ = try write(bytes, to: root)
        let result = LocalMetricsSnapshotReader.readSummary(directoryURL: root, period: try window())
        XCTAssertEqual(result.diagnostics.state, .complete)
        XCTAssertEqual(result.diagnostics.acceptedRecordCount, 2)
        XCTAssertEqual(result.summary?.audioFile.started, 0)
        XCTAssertEqual(result.summary?.audioFile.completed, 1)
        XCTAssertEqual(result.summary?.audioFile.recognizedWordsOnCompleted.sum, 3)
        XCTAssertFalse(String(reflecting: result).contains(canary))
    }

    func testMalformedTypedTerminalPoisonsSessionWithoutLeakingSyntheticPath() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = UUID(), syntheticPath = "/synthetic/not_a_user/private.txt"
        var bytes = try jsonLine(event(session, 101, .sessionStarted, .microphone))
        let invalid = LocalMetricsEvent(sessionID: session,
            timestamp: Date(timeIntervalSince1970: 110), kind: .transcriptionCompleted,
            source: .microphone, modelFileName: syntheticPath,
            recognizedWordCount: -7)
        bytes.append(try jsonLine(invalid))
        _ = try write(bytes, to: root)
        let result = LocalMetricsSnapshotReader.readSummary(directoryURL: root, period: try window())
        XCTAssertEqual(result.diagnostics.state, .partial)
        XCTAssertEqual(result.diagnostics.invalidRecordCount, 1)
        XCTAssertEqual(result.summary?.microphone.completed, 0)
        XCTAssertEqual(result.summary?.microphone.ambiguous, 1)
        XCTAssertEqual(result.summary?.microphone.incompleteAtPeriodEnd, 0)
        XCTAssertFalse(String(reflecting: result).contains(syntheticPath))
    }

    func testReversedTerminalOutsidePeriodMarksSnapshotPartial() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = UUID()
        var bytes = try jsonLine(event(session, 101, .sessionStarted, .microphone))
        bytes.append(try jsonLine(event(session, 90, .transcriptionCompleted, .microphone,
                                        words: 3)))
        _ = try write(bytes, to: root)
        let result = LocalMetricsSnapshotReader.readSummary(directoryURL: root, period: try window())
        XCTAssertEqual(result.diagnostics.acceptedRecordCount, 2)
        XCTAssertEqual(result.diagnostics.state, .partial)
        XCTAssertEqual(result.summary?.microphone.started, 1)
        XCTAssertEqual(result.summary?.microphone.completed, 0)
        XCTAssertEqual(result.summary?.microphone.ambiguous, 1)
    }

    func testUnknownContentKeyAndTornTailAreNotCountedOrEchoed() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = UUID(), canary = "SYNTHETIC_PRIVATE_TEXT_CANARY"
        var bytes = try jsonLine(event(session, 101, .sessionStarted, .microphone))
        let clean = try JSONEncoder().encode(event(session, 110, .transcriptionCompleted,
                                                   .microphone, words: 9))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: clean) as? [String: Any])
        object["transcriptText"] = canary
        bytes.append(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
        bytes.append(0x0A)
        bytes.append(Data("{\"schemaVersion\":1,\"eventID\":\"".utf8))
        _ = try write(bytes, to: root)
        let result = LocalMetricsSnapshotReader.readSummary(directoryURL: root, period: try window())
        XCTAssertEqual(result.diagnostics.state, .partial)
        XCTAssertEqual(result.diagnostics.invalidRecordCount, 1)
        XCTAssertEqual(result.diagnostics.tornTailCount, 1)
        XCTAssertEqual(result.summary?.microphone.completed, 0)
        XCTAssertFalse(String(reflecting: result).contains(canary))
    }

    func testDuplicateAndConflictingEventIDDoNotBecomeCompleted() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = UUID(), terminalID = UUID()
        let start = event(session, 101, .sessionStarted, .microphone)
        let terminal = event(session, 110, .transcriptionCompleted, .microphone,
                             eventID: terminalID, words: 5)
        let collision = event(session, 111, .sessionFailed, .microphone,
                              eventID: terminalID)
        var bytes = try jsonLine(start)
        bytes.append(try jsonLine(terminal))
        bytes.append(try jsonLine(terminal))
        bytes.append(try jsonLine(collision))
        _ = try write(bytes, to: root)
        let result = LocalMetricsSnapshotReader.readSummary(directoryURL: root, period: try window())
        XCTAssertEqual(result.diagnostics.state, .partial)
        XCTAssertEqual(result.diagnostics.acceptedRecordCount, 4)
        XCTAssertEqual(result.summary?.duplicateEventRecords, 2)
        XCTAssertEqual(result.summary?.conflictingEventIDGroups, 1)
        XCTAssertEqual(result.summary?.microphone.completed, 0)
        XCTAssertEqual(result.summary?.microphone.ambiguous, 1)
    }

    func testSymlinkAndLoosePermissionsNeverReadTheirPayload() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let outside = try canonicalTemporaryDirectory()
            .appendingPathComponent("clavune-outside-synthetic-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: outside) }
        let session = UUID()
        let outsideBytes = try jsonLine(event(session, 101, .sessionStarted, .microphone))
        try outsideBytes.write(to: outside)
        let link = root.appendingPathComponent("events-symlink.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let loose = try write(try jsonLine(event(UUID(), 102, .sessionStarted, .audioFile)),
                              to: root, name: "events-loose.jsonl")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: loose.path)
        let result = LocalMetricsSnapshotReader.readSummary(directoryURL: root, period: try window())
        XCTAssertEqual(result.diagnostics.state, .partial)
        XCTAssertEqual(result.diagnostics.unsafeOrUnreadableSegmentCount, 2)
        XCTAssertEqual(result.diagnostics.acceptedRecordCount, 0)
        XCTAssertEqual(result.summary?.microphone.started, 0)
        XCTAssertEqual(result.summary?.audioFile.started, 0)
    }

    func testExtendedACLOnDirectoryOrFileCannotAppearAsCompletePrivateHistory() throws {
        let exposedDirectory = try directory()
        defer { try? FileManager.default.removeItem(at: exposedDirectory) }
        try addSyntheticReadACL(exposedDirectory)
        let unavailable = LocalMetricsSnapshotReader.readSummary(
            directoryURL: exposedDirectory, period: try window())
        XCTAssertEqual(unavailable.diagnostics.state, .unavailable)
        XCTAssertEqual(unavailable.diagnostics.unavailableReason, .directoryUnsafe)
        XCTAssertNil(unavailable.summary)

        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = UUID()
        var bytes = try jsonLine(event(session, 101, .sessionStarted, .microphone))
        bytes.append(try jsonLine(event(session, 110, .transcriptionCompleted, .microphone,
                                        words: 3)))
        let file = try write(bytes, to: root)
        try addSyntheticReadACL(file)
        let partial = LocalMetricsSnapshotReader.readSummary(directoryURL: root, period: try window())
        XCTAssertEqual(partial.diagnostics.state, .partial)
        XCTAssertEqual(partial.diagnostics.unsafeOrUnreadableSegmentCount, 1)
        XCTAssertEqual(partial.diagnostics.acceptedRecordCount, 0)
        XCTAssertEqual(partial.summary?.microphone.completed, 0)
    }

    func testIntermediateSymlinkIsUnavailableNotTraversedOrMistakenForFreshEmpty() throws {
        let base = try canonicalTemporaryDirectory()
        let container = base.appendingPathComponent("clavune-link-fixture-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let realParent = container.appendingPathComponent("real", isDirectory: true)
        let metrics = realParent.appendingPathComponent("Metrics", isDirectory: true)
        try FileManager.default.createDirectory(at: metrics, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: metrics.path)
        _ = try write(try jsonLine(event(UUID(), 101, .sessionStarted, .microphone)), to: metrics)
        let link = container.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realParent)
        let linkedResult = LocalMetricsSnapshotReader.readSummary(
            directoryURL: link.appendingPathComponent("Metrics", isDirectory: true),
            period: try window())
        XCTAssertEqual(linkedResult.diagnostics.state, .unavailable)
        XCTAssertNil(linkedResult.summary)

        let broken = container.appendingPathComponent("broken", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: broken,
            withDestinationURL: container.appendingPathComponent("missing", isDirectory: true))
        let brokenResult = LocalMetricsSnapshotReader.readSummary(
            directoryURL: broken.appendingPathComponent("Metrics", isDirectory: true),
            period: try window())
        XCTAssertEqual(brokenResult.diagnostics.state, .unavailable)
        XCTAssertNil(brokenResult.summary)
    }

    func testInsecureDirectoryAndCapacityExcessAreUnavailableNotEmpty() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        let unsafe = LocalMetricsSnapshotReader.readSummary(directoryURL: root, period: try window())
        XCTAssertEqual(unsafe.diagnostics.state, .unavailable)
        XCTAssertNil(unsafe.summary)
        XCTAssertEqual(unsafe.diagnostics.unavailableReason, .directoryUnsafe)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        _ = try write(try jsonLine(event(UUID(), 101, .sessionStarted, .microphone)), to: root)
        let capped = LocalMetricsSnapshotReader.readSummary(directoryURL: root,
            period: try window(), limits: .init(totalBytes: 20, fileCount: 2, recordBytes: 20))
        XCTAssertEqual(capped.diagnostics.state, .unavailable)
        XCTAssertNil(capped.summary)
        XCTAssertEqual(capped.diagnostics.unavailableReason, .capacityExceeded)
    }

    func testRecordAndSegmentLimitsAreNotSilentTruncation() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let line = try jsonLine(event(UUID(), 101, .sessionStarted, .microphone))
        XCTAssertGreaterThan(line.count, 100)
        _ = try write(line, to: root, name: "events-first.jsonl")
        let longRecord = LocalMetricsSnapshotReader.readSummary(directoryURL: root,
            period: try window(), limits: .init(totalBytes: 10 * 1024 * 1024,
                                                fileCount: 2, recordBytes: 100))
        XCTAssertEqual(longRecord.diagnostics.state, .partial)
        XCTAssertEqual(longRecord.diagnostics.invalidRecordCount, 1)
        XCTAssertEqual(longRecord.diagnostics.acceptedRecordCount, 0)
        _ = try write(line, to: root, name: "events-second.jsonl")
        let tooManyFiles = LocalMetricsSnapshotReader.readSummary(directoryURL: root,
            period: try window(), limits: .init(totalBytes: 10 * 1024 * 1024,
                                                fileCount: 1, recordBytes: 16 * 1024))
        XCTAssertEqual(tooManyFiles.diagnostics.state, .unavailable)
        XCTAssertEqual(tooManyFiles.diagnostics.unavailableReason, .capacityExceeded)
        XCTAssertNil(tooManyFiles.summary)
    }

    func testDecodedEventCapRejectsBeforeRetainingFiftyThousandAndOne() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let line = try jsonLine(event(UUID(), 101, .sessionStarted, .microphone))
        var bytes = Data()
        bytes.reserveCapacity(line.count * (LocalStatisticsSummaryBuilder.maximumInputEvents + 1))
        for _ in 0...LocalStatisticsSummaryBuilder.maximumInputEvents { bytes.append(line) }
        XCTAssertLessThanOrEqual(bytes.count, LocalMetricsJournal.Limits().totalBytes)
        _ = try write(bytes, to: root)
        let result = LocalMetricsSnapshotReader.readSummary(directoryURL: root, period: try window())
        XCTAssertEqual(result.diagnostics.state, .unavailable)
        XCTAssertEqual(result.diagnostics.unavailableReason, .capacityExceeded)
        XCTAssertNil(result.summary)
    }

    func testCancellationReturnsNoSummaryWithoutOpeningSyntheticDirectory() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let result = LocalMetricsSnapshotReader.readSummary(directoryURL: root,
            period: try window(), limits: .init(), shouldCancel: { true })
        XCTAssertEqual(result.diagnostics.state, .unavailable)
        XCTAssertEqual(result.diagnostics.unavailableReason, .cancelled)
        XCTAssertNil(result.summary)
    }

    func testRepeatedRefreshReadsVisiblePrefixWithoutAccumulatingOldResult() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = UUID()
        let start = try jsonLine(event(session, 101, .sessionStarted, .microphone))
        let terminal = try jsonLine(event(session, 110, .transcriptionCompleted,
                                           .microphone, words: 2))
        let file = try write(start, to: root)
        let before = LocalMetricsSnapshotReader.readSummary(directoryURL: root, period: try window())
        XCTAssertEqual(before.summary?.microphone.completed, 0)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: terminal); try handle.close()
        let after = LocalMetricsSnapshotReader.readSummary(directoryURL: root, period: try window())
        XCTAssertEqual(after.summary?.microphone.completed, 1)
        XCTAssertEqual(after.diagnostics.acceptedRecordCount, 2)
        XCTAssertEqual(before.summary?.microphone.completed, 0)
    }

    func testHeldAppendAfterSizeCaptureCannotEnterEarlierPrefixCut() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = UUID()
        let start = try jsonLine(event(session, 101, .sessionStarted, .microphone))
        let terminal = try jsonLine(event(session, 110, .transcriptionCompleted,
                                           .microphone, words: 4))
        let file = try write(start, to: root)
        let handle = try FileHandle(forWritingTo: file)
        var appendFailure: Error?
        let cut = LocalMetricsSnapshotReader.readSummary(directoryURL: root,
            period: try window(), limits: .init(), shouldCancel: { false },
            afterCapturingSegmentSize: {
                do {
                    try handle.seekToEnd()
                    try handle.write(contentsOf: terminal)
                } catch { appendFailure = error }
            })
        try handle.close()
        XCTAssertNil(appendFailure)
        XCTAssertEqual(cut.diagnostics.state, .partial)
        XCTAssertTrue(cut.diagnostics.concurrentChangeDetected)
        XCTAssertEqual(cut.summary?.microphone.started, 1)
        XCTAssertEqual(cut.summary?.microphone.completed, 0)
        let later = LocalMetricsSnapshotReader.readSummary(directoryURL: root, period: try window())
        XCTAssertEqual(later.diagnostics.state, .complete)
        XCTAssertEqual(later.summary?.microphone.completed, 1)
    }
}
