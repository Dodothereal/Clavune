import Foundation
import XCTest
@testable import ClavuneApp
@testable import ClavuneCore

private final class HeldImporterFailure: @unchecked Sendable {
    let entered: XCTestExpectation
    private let gate = DispatchSemaphore(value: 0)
    init(_ entered: XCTestExpectation) { self.entered = entered }
    func read() throws -> SessionPCM {
        entered.fulfill()
        gate.wait()
        throw AudioFileImporter.Failure.durationLimit
    }
    func release() { gate.signal() }
}

/// Actual coordinator/admission and journal; only picker and reader are synthetic.
/// No microphone, audio file, system panel, model inference or network is used.
final class AudioImportFailureTaxonomyTests: UIFixtureAssertions {
    private func events(in directory: URL) throws -> [LocalMetricsEvent] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("events-") && $0.pathExtension == "jsonl" }
        return try files.flatMap { file in
            try Data(contentsOf: file).split(separator: 0x0A, omittingEmptySubsequences: true).map {
                try JSONDecoder().decode(LocalMetricsEvent.self, from: Data($0))
            }
        }
    }

    @MainActor private func assertReadFailure(_ label: String,
        read: @escaping @Sendable () throws -> SessionPCM,
        expected: DictationError) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clavune-file-failure-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = LocalMetricsJournal(directoryURL: directory)
        let fixture = try CoordinatorFixture(localMetricsJournal: journal, configureEnvironment: { environment in
            environment.chooseAudioToImport = { _ in URL(fileURLWithPath: "/synthetic-audio-never-opened.wav") }
            environment.readAudio = { _, _ in try read() }
        })

        fixture.coordinator.importAudio()
        await waitForOperation(fixture)
        XCTAssertEqual(fixture.coordinator.session.phase, .failed, label)
        XCTAssertEqual(fixture.coordinator.session.failure, expected, label)
        XCTAssertTrue(fixture.coordinator.audioFileSession, label)
        XCTAssertTrue(fixture.coordinator.message.contains("M4A (AAC-LC/ALAC)"), label)
        XCTAssertEqual(fixture.coordinator.microphone.state, .closed, label)
        XCTAssertEqual(fixture.resources.counts.value.constructed, 0, label)
        XCTAssertEqual(fixture.permissionCalls, 0, label)
        XCTAssertEqual(fixture.inference.counts.value.loads, 0, label)
        XCTAssertEqual(fixture.inference.counts.value.decodes, 0, label)
        XCTAssertTrue(fixture.coordinator.canImportAudio, label)
        XCTAssertNil(fixture.coordinator.dictationRecovery, label)

        let synchronized = await journal.synchronize()
        XCTAssertTrue(synchronized, label)
        let terminalEvents = try events(in: directory).filter {
            [.sessionFailed, .sessionCancelled, .sessionInterrupted, .transcriptionCompleted].contains($0.kind)
        }
        XCTAssertEqual(terminalEvents.count, 1, label)
        let terminal = try XCTUnwrap(terminalEvents.first, label)
        let sessionID = try XCTUnwrap(fixture.coordinator.session.id, label)
        XCTAssertEqual(terminal.kind, .sessionFailed, label)
        XCTAssertEqual(terminal.source, .audioFile, label)
        XCTAssertEqual(terminal.sessionID, sessionID, label)
        XCTAssertEqual(terminal.failureCode, expected.rawValue, label)
        let closed = await journal.close()
        XCTAssertTrue(closed, label)
    }

    @MainActor func testFileReadFailureCodesPreserveBoundsAndEmptyAudioWithoutChangingGuidance() async throws {
        try await assertReadFailure("durationLimit", read: {
            throw AudioFileImporter.Failure.durationLimit
        }, expected: .durationLimit)
        try await assertReadFailure("noAudio", read: {
            throw AudioFileImporter.Failure.noAudio
        }, expected: .noAudio)
        // Negative controls: neither bytes nor codec failure is a duration error.
        try await assertReadFailure("tooLarge", read: {
            throw AudioFileImporter.Failure.tooLarge
        }, expected: .unsupportedFormat)
        try await assertReadFailure("unsupportedFormat", read: {
            throw AudioFileImporter.Failure.unsupportedFormat
        }, expected: .unsupportedFormat)
        try await assertReadFailure("invalidFile", read: {
            throw AudioFileImporter.Failure.invalidFile
        }, expected: .unsupportedFormat)
        try await assertReadFailure("changedFile", read: {
            throw AudioFileImporter.Failure.changedFile
        }, expected: .unsupportedFormat)
        try await assertReadFailure("dictationError", read: {
            throw DictationError.audioUnavailable
        }, expected: .audioUnavailable)
        try await assertReadFailure("unknownError", read: {
            throw NSError(domain: "synthetic-reader", code: 1)
        }, expected: .unsupportedFormat)
    }

    @MainActor func testLateDurationFailureCannotReplaceExplicitImportCancellation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clavune-file-cancel-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = LocalMetricsJournal(directoryURL: directory)
        let entered = expectation(description: "synthetic reader entered")
        let held = HeldImporterFailure(entered)
        defer { held.release() }
        let fixture = try CoordinatorFixture(localMetricsJournal: journal, configureEnvironment: { environment in
            environment.chooseAudioToImport = { _ in URL(fileURLWithPath: "/synthetic-audio-never-opened.wav") }
            environment.readAudio = { _, _ in try held.read() }
        })
        fixture.coordinator.importAudio()
        await fulfillment(of: [entered], timeout: 2)
        let sessionID = try XCTUnwrap(fixture.coordinator.session.id)
        fixture.coordinator.cancel()
        held.release()
        await waitForOperation(fixture)
        XCTAssertEqual(fixture.coordinator.session.phase, .cancelled)
        XCTAssertNil(fixture.coordinator.session.failure)
        XCTAssertFalse(fixture.coordinator.audioFilePending)
        XCTAssertTrue(fixture.coordinator.canImportAudio)
        XCTAssertEqual(fixture.coordinator.microphone.state, .closed)
        XCTAssertEqual(fixture.inference.counts.value.loads, 0)

        let synchronized = await journal.synchronize()
        XCTAssertTrue(synchronized)
        let terminalEvents = try events(in: directory).filter {
            [.sessionFailed, .sessionCancelled, .sessionInterrupted, .transcriptionCompleted].contains($0.kind)
        }
        XCTAssertEqual(terminalEvents.count, 1)
        let terminal = try XCTUnwrap(terminalEvents.first)
        XCTAssertEqual(terminal.sessionID, sessionID)
        XCTAssertEqual(terminal.kind, .sessionCancelled)
        XCTAssertEqual(terminal.source, .audioFile)
        XCTAssertEqual(terminal.failureCode, DictationError.cancelled.rawValue)
        let closed = await journal.close()
        XCTAssertTrue(closed)
    }
}
