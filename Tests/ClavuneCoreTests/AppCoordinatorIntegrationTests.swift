import AVFoundation
import XCTest
@testable import ClavuneApp
@testable import ClavuneCore

private final class HeldMetricsWrite: @unchecked Sendable {
    let entered: XCTestExpectation
    let writtenText = FixtureValue<String?>(nil)
    private let release = DispatchSemaphore(value: 0)

    init(_ entered: XCTestExpectation) { self.entered = entered }
    func write(_ text: String) {
        writtenText.value = text
        entered.fulfill()
        release.wait()
    }
    func resume() { release.signal() }
}

private final class HeldMetricsAudioRead: @unchecked Sendable {
    let entered: XCTestExpectation
    private let release = DispatchSemaphore(value: 0)

    init(_ entered: XCTestExpectation) { self.entered = entered }
    func read() -> SessionPCM {
        entered.fulfill()
        release.wait()
        return SessionPCM(samples: [0.1, -0.1])
    }
    func resume() { release.signal() }
}

final class AppCoordinatorIntegrationTests: XCTestCase {
    @MainActor private func startRecording(_ fixture: CoordinatorFixture) async {
        let recording = expectation(description: "actual coordinator recording")
        let finished = expectation(description: "actual startup task completed")
        fixture.coordinator.start()
        fixture.observePhase(.recording, expectation: recording)
        fixture.observeOperationFinished(finished)
        await fulfillment(of: [recording, finished], timeout: 2)
    }
    @MainActor private func stopToReview(_ fixture: CoordinatorFixture) async {
        let reviewed = expectation(description: "actual coordinator result")
        fixture.observePhase(.review, expectation: reviewed)
        fixture.coordinator.stop()
        await fulfillment(of: [reviewed], timeout: 2)
        // Published review is emitted before the task's defer clears operationPending.
        let finished = expectation(description: "result task completed")
        fixture.observeOperationFinished(finished)
        await fulfillment(of: [finished], timeout: 2)
    }
    @MainActor private func waitForOperation(_ fixture: CoordinatorFixture) async {
        guard fixture.coordinator.operationPending else { return }
        let finished = expectation(description: "coordinator operation completed")
        fixture.observeOperationFinished(finished)
        await fulfillment(of: [finished], timeout: 2)
    }
    private func metricsDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clavune-coordinator-metrics-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return url
    }
    private func metricsEvents(in directory: URL) throws -> [LocalMetricsEvent] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("events-") && $0.pathExtension == "jsonl" }
        return try files.flatMap { file in
            try Data(contentsOf: file).split(separator: 0x0A, omittingEmptySubsequences: true).map {
                try JSONDecoder().decode(LocalMetricsEvent.self, from: Data($0))
            }
        }
    }

    @MainActor func testCaptureCompletionMetricsDistinguishRequestedFromDetectedLanguage() async throws {
        for mode in LanguageMode.allCases {
            let directory = try metricsDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let journal = LocalMetricsJournal(directoryURL: directory)
            let fixture = try CoordinatorFixture(localMetricsJournal: journal)
            fixture.coordinator.language = mode

            await startRecording(fixture)
            await stopToReview(fixture)
            XCTAssertEqual(fixture.inference.receivedLanguage.value, mode)
            let synchronized = await journal.synchronize()
            XCTAssertTrue(synchronized)

            let completed = try metricsEvents(in: directory).filter { $0.kind == .transcriptionCompleted }
            XCTAssertEqual(completed.count, 1)
            let event = try XCTUnwrap(completed.first)
            XCTAssertEqual(event.source, .microphone)
            XCTAssertEqual(event.requestedLanguage, mode.rawValue)
            XCTAssertEqual(event.detectedLanguageID, mode == .auto ? 1 : nil)
            let closed = await journal.close()
            XCTAssertTrue(closed)
        }
    }

    @MainActor func testAudioImportCompletionMetricsDistinguishRequestedFromDetectedLanguage() async throws {
        for mode in LanguageMode.allCases {
            let directory = try metricsDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let journal = LocalMetricsJournal(directoryURL: directory)
            let fixture = try CoordinatorFixture(localMetricsJournal: journal, configureEnvironment: { environment in
                environment.chooseAudioToImport = { _ in URL(fileURLWithPath: "/synthetic-audio-never-opened.wav") }
                environment.readAudio = { _, _ in SessionPCM(samples: [0.1, -0.1]) }
            })
            fixture.coordinator.language = mode

            fixture.coordinator.importAudio()
            await waitForOperation(fixture)
            XCTAssertEqual(fixture.coordinator.session.phase, .review)
            XCTAssertEqual(fixture.inference.receivedLanguage.value, mode)
            let synchronized = await journal.synchronize()
            XCTAssertTrue(synchronized)

            let completed = try metricsEvents(in: directory).filter { $0.kind == .transcriptionCompleted }
            XCTAssertEqual(completed.count, 1)
            let event = try XCTUnwrap(completed.first)
            XCTAssertEqual(event.source, .audioFile)
            XCTAssertEqual(event.requestedLanguage, mode.rawValue)
            XCTAssertEqual(event.detectedLanguageID, mode == .auto ? 1 : nil)
            let closed = await journal.close()
            XCTAssertTrue(closed)
        }
    }

    @MainActor func testFailureMetricsUseTheFailureTimeForEndToEndElapsed() async throws {
        let directory = try metricsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = LocalMetricsJournal(directoryURL: directory)
        let fixture = try CoordinatorFixture(localMetricsJournal: journal)
        await startRecording(fixture)
        let sessionID = try XCTUnwrap(fixture.coordinator.session.id)

        fixture.now = 2_100
        let failed = expectation(description: "active session failure delivered")
        fixture.observePhase(.failed, expectation: failed)
        fixture.resources.fail(session: sessionID, error: .audioUnavailable)
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertEqual(fixture.coordinator.session.phase, .failed)
        let synced = await journal.synchronize()
        XCTAssertTrue(synced)

        let failure = try XCTUnwrap(try metricsEvents(in: directory).first { $0.kind == .sessionFailed })
        XCTAssertEqual(failure.sessionID, sessionID)
        XCTAssertEqual(failure.endToEndSeconds, AVAudioTime.seconds(forHostTime: 2_000))
        XCTAssertEqual(failure.failureCode, DictationError.audioUnavailable.rawValue)
        let journalClosed = await journal.close()
        XCTAssertTrue(journalClosed)
    }

    @MainActor func testCancellationMetricsCaptureElapsedTimeAndRSSAtRequestBeforeDrain() async throws {
        let directory = try metricsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = LocalMetricsJournal(directoryURL: directory)
        let sampleCalls = FixtureValue(0)
        let startUsage = LocalProcessUsageSnapshot(userCPUSeconds: 2, systemCPUSeconds: 1,
                                                   peakRSSBytes: 6_000)
        let terminalUsage = LocalProcessUsageSnapshot(userCPUSeconds: 5.5, systemCPUSeconds: 4.75,
                                                      peakRSSBytes: 12_345)
        let fixture = try CoordinatorFixture(localMetricsJournal: journal, processUsageSnapshot: {
            let call = sampleCalls.value
            sampleCalls.value = call + 1
            return call == 0 ? startUsage : terminalUsage
        })
        await startRecording(fixture)
        let sessionID = try XCTUnwrap(fixture.coordinator.session.id)
        XCTAssertEqual(sampleCalls.value, 1, "The session start captures its baseline")
        let submitted = expectation(description: "cancel close queued while service drain is paused")
        fixture.queue.pause(nextSubmission: submitted)

        fixture.now = 2_100
        fixture.coordinator.cancel()
        XCTAssertEqual(sampleCalls.value, 2, "Start and cancellation snapshots use the injected provider")
        await fulfillment(of: [submitted], timeout: 2)
        fixture.now = 9_000 // Deliberately advance host time while the close is still queued.
        let synced = await journal.synchronize()
        XCTAssertTrue(synced)

        let cancellation = try XCTUnwrap(try metricsEvents(in: directory).first { $0.kind == .sessionCancelled })
        XCTAssertEqual(cancellation.sessionID, sessionID)
        XCTAssertEqual(cancellation.endToEndSeconds, AVAudioTime.seconds(forHostTime: 2_000))
        XCTAssertEqual(try XCTUnwrap(cancellation.processCPUUserSeconds), 3.5, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(cancellation.processCPUSystemSeconds), 3.75, accuracy: 0.000_001)
        XCTAssertEqual(cancellation.processPeakRSSBytesAtEvent, 12_345)
        XCTAssertEqual(sampleCalls.value, 2)

        let closed = expectation(description: "cancel close drained after metrics snapshot")
        fixture.observeCloseFinished(closed)
        fixture.queue.resume()
        await fulfillment(of: [closed], timeout: 2)
        XCTAssertEqual(sampleCalls.value, 2, "Resource drain must not resample the terminal event")
        let journalClosed = await journal.close()
        XCTAssertTrue(journalClosed)
    }

    @MainActor func testRepeatedAudioImportCancellationSamplesOnceBeforeDrain() async throws {
        let directory = try metricsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = LocalMetricsJournal(directoryURL: directory)
        let sampleCalls = FixtureValue(0)
        let entered = expectation(description: "audio import read is holding admitted work")
        let heldRead = HeldMetricsAudioRead(entered)
        defer { heldRead.resume() }
        let url = URL(fileURLWithPath: "/fixture-audio-never-read.wav")
        let fixture = try CoordinatorFixture(localMetricsJournal: journal, processUsageSnapshot: {
            sampleCalls.update { $0 += 1 }
            return LocalProcessUsageSnapshot(userCPUSeconds: 4, systemCPUSeconds: 2, peakRSSBytes: 34_567)
        }, configureEnvironment: { environment in
            environment.chooseAudioToImport = { _ in url }
            environment.readAudio = { _, _ in heldRead.read() }
        })

        fixture.coordinator.importAudio()
        await fulfillment(of: [entered], timeout: 2)
        let sessionID = try XCTUnwrap(fixture.coordinator.session.id)
        XCTAssertEqual(sampleCalls.value, 1, "Import start records its baseline")
        fixture.coordinator.cancel()
        XCTAssertTrue(fixture.coordinator.audioFilePending)
        XCTAssertTrue(fixture.coordinator.operationPending)
        fixture.coordinator.interruptForPrivacy()
        XCTAssertEqual(sampleCalls.value, 2, "Repeated cancellation must not resample the terminal event")

        let syncedBeforeDrain = await journal.synchronize()
        XCTAssertTrue(syncedBeforeDrain)
        let beforeDrain = try metricsEvents(in: directory)
        let terminalBeforeDrain = beforeDrain.filter {
            $0.kind == .transcriptionCompleted || $0.kind == .sessionFailed ||
                $0.kind == .sessionCancelled || $0.kind == .sessionInterrupted
        }
        XCTAssertEqual(terminalBeforeDrain.count, 1)
        XCTAssertEqual(terminalBeforeDrain.first?.sessionID, sessionID)
        XCTAssertEqual(terminalBeforeDrain.first?.kind, .sessionCancelled)

        heldRead.resume()
        await waitForOperation(fixture)
        XCTAssertEqual(sampleCalls.value, 2)
        let syncedAfterDrain = await journal.synchronize()
        XCTAssertTrue(syncedAfterDrain)
        let afterDrain = try metricsEvents(in: directory).filter {
            $0.kind == .transcriptionCompleted || $0.kind == .sessionFailed ||
                $0.kind == .sessionCancelled || $0.kind == .sessionInterrupted
        }
        XCTAssertEqual(afterDrain.count, 1)
        let closed = await journal.close()
        XCTAssertTrue(closed)
    }

    @MainActor func testSessionMetricsUseFreshBaselineAfterCounterReset() async throws {
        let directory = try metricsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = LocalMetricsJournal(directoryURL: directory)
        let sampleCalls = FixtureValue(0)
        let snapshots = [
            LocalProcessUsageSnapshot(userCPUSeconds: 10, systemCPUSeconds: 20, peakRSSBytes: 10_000),
            LocalProcessUsageSnapshot(userCPUSeconds: 15, systemCPUSeconds: 25, peakRSSBytes: 11_000),
            LocalProcessUsageSnapshot(userCPUSeconds: 100, systemCPUSeconds: 200, peakRSSBytes: 20_000),
            LocalProcessUsageSnapshot(userCPUSeconds: 90, systemCPUSeconds: 190, peakRSSBytes: 19_000)
        ]
        let fixture = try CoordinatorFixture(localMetricsJournal: journal, processUsageSnapshot: {
            let call = sampleCalls.value
            sampleCalls.value = call + 1
            return snapshots[min(call, snapshots.count - 1)]
        })

        await startRecording(fixture)
        let firstSessionID = try XCTUnwrap(fixture.coordinator.session.id)
        fixture.coordinator.cancel()
        let firstClosed = expectation(description: "first session cancellation drained")
        fixture.observeCloseFinished(firstClosed)
        await fulfillment(of: [firstClosed], timeout: 2)

        await startRecording(fixture)
        let secondSessionID = try XCTUnwrap(fixture.coordinator.session.id)
        XCTAssertNotEqual(secondSessionID, firstSessionID)
        XCTAssertEqual(sampleCalls.value, 3)
        XCTAssertEqual(fixture.coordinator.metrics?.processUsageAtStart, snapshots[2])
        fixture.coordinator.cancel()
        let secondClosed = expectation(description: "second session cancellation drained")
        fixture.observeCloseFinished(secondClosed)
        await fulfillment(of: [secondClosed], timeout: 2)
        XCTAssertEqual(sampleCalls.value, 4)

        let synced = await journal.synchronize()
        XCTAssertTrue(synced)
        let cancellations = try metricsEvents(in: directory).filter { $0.kind == .sessionCancelled }
        let first = try XCTUnwrap(cancellations.first { $0.sessionID == firstSessionID })
        let second = try XCTUnwrap(cancellations.first { $0.sessionID == secondSessionID })
        XCTAssertEqual(try XCTUnwrap(first.processCPUUserSeconds), 5, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(first.processCPUSystemSeconds), 5, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(second.processCPUUserSeconds), 0, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(second.processCPUSystemSeconds), 0, accuracy: 0.000_001)
        let closed = await journal.close()
        XCTAssertTrue(closed)
    }

    @MainActor func testPickerCancellationDoesNotResamplePriorTerminalSessionMetrics() async throws {
        let directory = try metricsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = LocalMetricsJournal(directoryURL: directory)
        let sampleCalls = FixtureValue(0)
        let url = URL(fileURLWithPath: "/fixture-audio-never-read.wav")
        var owner: AppCoordinator?
        var pickerCalls = 0
        let fixture = try CoordinatorFixture(localMetricsJournal: journal, processUsageSnapshot: {
            sampleCalls.update { $0 += 1 }
            return LocalProcessUsageSnapshot(userCPUSeconds: 7, systemCPUSeconds: 3, peakRSSBytes: 45_678)
        }, configureEnvironment: { environment in
            environment.chooseAudioToImport = { _ in
                pickerCalls += 1
                if pickerCalls == 1 { return url }
                owner?.cancel()
                owner?.interruptForPrivacy()
                return nil
            }
            environment.readAudio = { _, _ in throw DictationError.unsupportedFormat }
        })
        owner = fixture.coordinator

        fixture.coordinator.importAudio()
        await waitForOperation(fixture)
        XCTAssertEqual(fixture.coordinator.session.phase, .failed)
        let priorSessionID = try XCTUnwrap(fixture.coordinator.metrics?.session)
        XCTAssertEqual(sampleCalls.value, 2, "Prior session has one start and one terminal snapshot")
        let syncedBeforePickerCancel = await journal.synchronize()
        XCTAssertTrue(syncedBeforePickerCancel)
        let priorTerminalEvents = try metricsEvents(in: directory).filter {
            $0.kind == .sessionFailed || $0.kind == .sessionCancelled || $0.kind == .sessionInterrupted
        }
        XCTAssertEqual(priorTerminalEvents.count, 1)
        XCTAssertEqual(priorTerminalEvents.first?.kind, .sessionFailed)

        fixture.coordinator.importAudio()
        XCTAssertEqual(pickerCalls, 2)
        XCTAssertFalse(fixture.coordinator.audioFilePending)
        XCTAssertFalse(fixture.coordinator.busy)
        XCTAssertEqual(fixture.coordinator.metrics?.session, priorSessionID)
        XCTAssertEqual(sampleCalls.value, 2, "Picker cancellations must not sample stale prior-session metrics")
        let syncedAfterPickerCancel = await journal.synchronize()
        XCTAssertTrue(syncedAfterPickerCancel)
        let terminalAfterPickerCancel = try metricsEvents(in: directory).filter {
            $0.kind == .sessionFailed || $0.kind == .sessionCancelled || $0.kind == .sessionInterrupted
        }
        XCTAssertEqual(terminalAfterPickerCancel.count, 1)
        XCTAssertEqual(terminalAfterPickerCancel.first?.kind, .sessionFailed)
        let closed = await journal.close()
        XCTAssertTrue(closed)
    }

    @MainActor func testIdleDocumentActionsDoNotReuseCancelledSessionMetadataOrRevisions() async throws {
        let directory = try metricsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = LocalMetricsJournal(directoryURL: directory)
        var selectedURL: URL?
        let fixture = try CoordinatorFixture(localMetricsJournal: journal, configureEnvironment: { environment in
            environment.chooseTranscriptToOpen = { _ in selectedURL }
            environment.readTranscript = { _ in "loaded document has three words" }
        })
        await startRecording(fixture)
        let cancelledSessionID = try XCTUnwrap(fixture.coordinator.session.id)
        let cancelled = expectation(description: "capture cancellation drained before document action")
        fixture.coordinator.cancel()
        // Subscribe after cancel has synchronously entered the close state, so
        // @Published's initial false value cannot satisfy the drain expectation.
        fixture.observeCloseFinished(cancelled)
        await fulfillment(of: [cancelled], timeout: 2)

        // Picker cancellation is an idle document action while old session metrics
        // still exist. It must get its own identity and no stale model/revision data.
        fixture.coordinator.openTranscript()
        selectedURL = URL(fileURLWithPath: "/fixture-transcript-never-opened.txt")
        fixture.coordinator.openTranscript()
        await waitForOperation(fixture)
        let synced = await journal.synchronize()
        XCTAssertTrue(synced)

        let events = try metricsEvents(in: directory)
        let opens = events.filter { $0.kind == .reviewAction && $0.reviewAction == .open }
        XCTAssertEqual(opens.count, 2)
        let cancelledOpen = try XCTUnwrap(opens.first { $0.actionSucceeded == false })
        let loadedOpen = try XCTUnwrap(opens.first { $0.actionSucceeded == true })
        for event in [cancelledOpen, loadedOpen] {
            XCTAssertEqual(event.source, .transcriptFile)
            XCTAssertNil(event.requestedLanguage)
            XCTAssertNil(event.modelFileName)
            XCTAssertNil(event.modelSHA256)
            XCTAssertNil(event.backendFingerprint)
            XCTAssertEqual(event.editorRevisionCount, 0)
            XCTAssertNotEqual(event.sessionID, cancelledSessionID)
        }
        XCTAssertEqual(cancelledOpen.rawWordCount, 0)
        XCTAssertEqual(cancelledOpen.editedWordCount, 0)
        XCTAssertEqual(loadedOpen.rawWordCount, 5)
        XCTAssertEqual(loadedOpen.editedWordCount, 5)
        let closed = await journal.close()
        XCTAssertTrue(closed)
    }

    @MainActor func testSaveMetricsUseTheTextAndRevisionSnapshotSubmittedToWriter() async throws {
        let directory = try metricsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = LocalMetricsJournal(directoryURL: directory)
        let entered = expectation(description: "save writer received the captured snapshot")
        let write = HeldMetricsWrite(entered)
        let fixture = try CoordinatorFixture(localMetricsJournal: journal, configureEnvironment: { environment in
            environment.chooseTranscriptToSave = { _ in URL(fileURLWithPath: "/fixture-save-never-written.txt") }
            environment.writeTranscript = { text, _ in write.write(text) }
        })
        await startRecording(fixture)
        await stopToReview(fixture)
        fixture.coordinator.editedText = "one two three four"
        fixture.coordinator.saveTranscript()
        await fulfillment(of: [entered], timeout: 2)
        fixture.coordinator.editedText = "later edits changed this snapshot"
        write.resume()
        await waitForOperation(fixture)
        XCTAssertEqual(write.writtenText.value, "one two three four")
        XCTAssertTrue(fixture.coordinator.hasUnsavedReview)
        let synced = await journal.synchronize()
        XCTAssertTrue(synced)

        let save = try XCTUnwrap(try metricsEvents(in: directory).first {
            $0.kind == .reviewAction && $0.reviewAction == .save && $0.actionSucceeded == true
        })
        XCTAssertEqual(save.editedWordCount, 4)
        XCTAssertEqual(save.editorRevisionCount, 1)
        let closed = await journal.close()
        XCTAssertTrue(closed)
    }

    @MainActor func testCanonicalEquivalentDraftEditIsDirtyAndAdvancesRevision() async throws {
        let directory = try metricsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = LocalMetricsJournal(directoryURL: directory)
        let selected = URL(fileURLWithPath: "/fixture-normalization-review-never-opened.txt")
        let composed = "\u{00E9}", decomposed = "e\u{0301}"
        let written = FixtureValue<Data?>(nil)
        let fixture = try CoordinatorFixture(localMetricsJournal: journal,
            configureEnvironment: { environment in
                environment.chooseTranscriptToOpen = { _ in selected }
                environment.readTranscript = { _ in composed }
                environment.chooseTranscriptToSave = { _ in selected }
                environment.writeTranscript = { text, _ in written.value = Data(text.utf8) }
            })
        fixture.coordinator.openTranscript()
        await waitForOperation(fixture)
        XCTAssertFalse(fixture.coordinator.hasUnsavedReview)

        fixture.coordinator.editedText = decomposed
        XCTAssertTrue(fixture.coordinator.hasUnsavedReview)
        fixture.coordinator.saveTranscript()
        await waitForOperation(fixture)
        XCTAssertEqual(written.value, Data(decomposed.utf8))

        let synchronized = await journal.synchronize()
        XCTAssertTrue(synchronized)
        let save = try XCTUnwrap(try metricsEvents(in: directory).first {
            $0.kind == .reviewAction && $0.reviewAction == .save && $0.actionSucceeded == true
        })
        XCTAssertEqual(save.editorRevisionCount, 1)
        let closed = await journal.close()
        XCTAssertTrue(closed)
    }

    @MainActor func testCanonicalEquivalentChangesDuringSaveAndQuitCannotReuseStaleSnapshots() async throws {
        let directory = try metricsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = LocalMetricsJournal(directoryURL: directory)
        let entered = expectation(description: "save snapshot reached writer")
        let writer = HeldMetricsWrite(entered)
        let selected = URL(fileURLWithPath: "/fixture-normalization-snapshot-never-opened.txt")
        let composed = "\u{00E9}", decomposed = "e\u{0301}"
        var owner: AppCoordinator?, confirmations = 0, changeQuitSnapshot = false
        let fixture = try CoordinatorFixture(localMetricsJournal: journal,
            configureEnvironment: { environment in
                environment.chooseTranscriptToOpen = { _ in selected }
                environment.readTranscript = { _ in composed }
                environment.chooseTranscriptToSave = { _ in selected }
                environment.writeTranscript = { text, _ in writer.write(text) }
                environment.confirmUnsavedReviewQuit = { _ in
                    confirmations += 1
                    if changeQuitSnapshot { owner?.editedText = decomposed }
                    return .discard
                }
            })
        owner = fixture.coordinator
        fixture.coordinator.openTranscript()
        await waitForOperation(fixture)
        fixture.coordinator.editedText = decomposed
        XCTAssertTrue(fixture.coordinator.hasUnsavedReview)

        fixture.coordinator.saveTranscript()
        await fulfillment(of: [entered], timeout: 2)
        fixture.coordinator.editedText = composed
        writer.resume()
        await waitForOperation(fixture)
        XCTAssertEqual(Data(try XCTUnwrap(writer.writtenText.value).utf8), Data(decomposed.utf8))
        XCTAssertTrue(fixture.coordinator.hasUnsavedReview,
                      "An equivalent but byte-distinct edit after Save remains unsaved")
        XCTAssertEqual(fixture.coordinator.message,
                       "Textstand gespeichert. Neuere Änderungen sind noch nicht gespeichert.")

        let synchronized = await journal.synchronize()
        XCTAssertTrue(synchronized)
        let save = try XCTUnwrap(try metricsEvents(in: directory).first {
            $0.kind == .reviewAction && $0.reviewAction == .save && $0.actionSucceeded == true
        })
        XCTAssertEqual(save.editorRevisionCount, 1, "The save records its submitted revision snapshot")

        changeQuitSnapshot = true
        fixture.coordinator.quit()
        XCTAssertEqual(confirmations, 1)
        XCTAssertEqual(fixture.coordinator.session.phase, .review,
                       "A stale Discard decision cannot apply after the draft changes during confirmation")
        XCTAssertEqual(Data(fixture.coordinator.editedText.utf8), Data(decomposed.utf8))
        XCTAssertFalse(fixture.coordinator.hasUnsavedReview)
        XCTAssertEqual(fixture.terminationCalls, 0)
        XCTAssertFalse(fixture.coordinator.busy)
        let closed = await journal.close()
        XCTAssertTrue(closed)
    }

    @MainActor func testInjectedJournalIsSuppressedForFunctionalQAMetrics() async throws {
        let directory = try metricsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = LocalMetricsJournal(directoryURL: directory)
        let configuration = try AppLaunchConfiguration.parse(environment: [
            "CLAVUNE_QA_PROFILE": "metrics-test",
            "CLAVUNE_QA_FUNCTIONAL": "synthetic-v1"
        ])
        let fixture = try CoordinatorFixture(launchConfiguration: configuration, localMetricsJournal: journal,
            configureEnvironment: { environment in
                environment.chooseAudioToImport = { _ in URL(fileURLWithPath: "/fixture-audio-never-read.wav") }
                environment.readAudio = { _, _ in SessionPCM(samples: [0.1, -0.1]) }
            })
        XCTAssertTrue(fixture.coordinator.canImportAudio)
        fixture.coordinator.importAudio()
        await waitForOperation(fixture)
        XCTAssertEqual(fixture.coordinator.session.phase, .review)
        let synced = await journal.synchronize()
        XCTAssertTrue(synced)
        XCTAssertTrue(try metricsEvents(in: directory).isEmpty,
            "An injected journal must not enable metrics in a QA launch configuration")
        let closed = await journal.close()
        XCTAssertTrue(closed)
    }

    @MainActor func testStopTimestampTraversesActualCoordinatorAndServiceBeforeDelayedDelivery() async throws {
        let fixture = try CoordinatorFixture()
        await startRecording(fixture)
        let submitted = expectation(description: "production stop enqueued")
        fixture.queue.pause(nextSubmission: submitted)
        fixture.now = 1_000
        fixture.coordinator.stop()
        XCTAssertEqual(fixture.coordinator.metrics?.requestedStop, 1_000)
        fixture.now = 9_000 // advances before Task delivery AND before control-queue execution.
        await fulfillment(of: [submitted], timeout: 2)
        XCTAssertTrue(fixture.resources.counts.value.stopCutoffs.isEmpty)
        let reviewed = expectation(description: "stop completed")
        fixture.observePhase(.review, expectation: reviewed)
        fixture.queue.resume()
        await fulfillment(of: [reviewed], timeout: 2)
        XCTAssertEqual(fixture.resources.counts.value.stopCutoffs, [1_000])
        XCTAssertEqual(fixture.coordinator.metrics?.requestedStop, 1_000)
        XCTAssertEqual(fixture.inference.counts.value.decodes, 1)
    }
    @MainActor func testCancelWithEmptyEditedTextClearsActualCoordinatorRawReview() async throws {
        let fixture = try CoordinatorFixture()
        await startRecording(fixture); await stopToReview(fixture)
        XCTAssertFalse(fixture.coordinator.session.rawTranscript.isEmpty)
        fixture.coordinator.editedText = ""
        fixture.coordinator.cancel()
        XCTAssertEqual(fixture.coordinator.session.phase, .cancelled)
        XCTAssertTrue(fixture.coordinator.session.rawTranscript.isEmpty)
        XCTAssertTrue(fixture.coordinator.editedText.isEmpty)
        let closed = expectation(description: "cancel acknowledged")
        fixture.observeCloseFinished(closed)
        await fulfillment(of: [closed], timeout: 2)
    }
    @MainActor func testActualCoordinatorRemainsMicClosingUntilServiceAcknowledges() async throws {
        let fixture = try CoordinatorFixture()
        await startRecording(fixture)
        let submitted = expectation(description: "actual cancel enqueued")
        fixture.queue.pause(nextSubmission: submitted)
        fixture.coordinator.cancel()
        await fulfillment(of: [submitted], timeout: 2)
        XCTAssertEqual(fixture.coordinator.session.phase, .cancelled)
        XCTAssertEqual(fixture.coordinator.microphone.state, .closing)
        XCTAssertTrue(fixture.coordinator.busy)
        XCTAssertEqual(AppIcon.symbol(for: fixture.coordinator.session.phase,
            microphone: fixture.coordinator.microphone.state), "mic.fill")
        XCTAssertEqual(fixture.resources.counts.value.closed, 0)
        let closed = expectation(description: "actual close acknowledged")
        fixture.observeCloseFinished(closed)
        fixture.queue.resume()
        await fulfillment(of: [closed], timeout: 2)
        XCTAssertEqual(fixture.coordinator.microphone.state, .closed)
        XCTAssertEqual(fixture.resources.counts.value.closed, 1)
    }
    @MainActor func testCancelAfterServiceEnqueueInvalidatesActualStartupBeforeFactory() async throws {
        let fixture = try CoordinatorFixture()
        let submitted = expectation(description: "actual startup enqueued")
        fixture.queue.pause(nextSubmission: submitted)
        fixture.coordinator.start()
        await fulfillment(of: [submitted], timeout: 2)
        fixture.coordinator.cancel()
        let finished = expectation(description: "cancelled startup completed")
        fixture.observeOperationFinished(finished)
        let closed = expectation(description: "cancel close acknowledged")
        fixture.observeCloseFinished(closed)
        fixture.queue.resume()
        await fulfillment(of: [finished, closed], timeout: 2)
        XCTAssertEqual(fixture.resources.counts.value.constructed, 0)
        XCTAssertEqual(fixture.resources.counts.value.opened, 0)
        XCTAssertEqual(fixture.coordinator.session.phase, .cancelled)
    }
    @MainActor func testPrivacyChangeAfterServiceEnqueuePreventsActualResourceConstruction() async throws {
        let fixture = try CoordinatorFixture()
        let submitted = expectation(description: "actual startup enqueued")
        fixture.queue.pause(nextSubmission: submitted)
        fixture.coordinator.start()
        await fulfillment(of: [submitted], timeout: 2)
        fixture.privacy.value = false
        let finished = expectation(description: "privacy failure completed")
        fixture.observeOperationFinished(finished)
        fixture.queue.resume()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(fixture.resources.counts.value.constructed, 0)
        XCTAssertEqual(fixture.coordinator.session.failure, .privacyBlocked)
    }
    @MainActor func testPrivacyChangeDuringActualServiceOpenClosesWithoutPumping() async throws {
        let fixture = try CoordinatorFixture()
        let privacy = fixture.privacy
        fixture.resources.duringOpen = { privacy.value = false }
        fixture.coordinator.start()
        let finished = expectation(description: "post-open privacy failure completed")
        fixture.observeOperationFinished(finished)
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(fixture.resources.counts.value.opened, 1)
        XCTAssertEqual(fixture.resources.counts.value.closed, 1)
        XCTAssertEqual(fixture.resources.counts.value.pumped, 0)
        XCTAssertEqual(fixture.coordinator.microphone.state, .closed)
        XCTAssertEqual(fixture.coordinator.session.failure, .privacyBlocked)
    }
    @MainActor func testSynchronousResourceFailureCannotBecomeSuccessfulStartup() async throws {
        let fixture = try CoordinatorFixture()
        fixture.resources.failDuringOpen = true
        fixture.coordinator.start()
        let finished = expectation(description: "failed startup drained")
        fixture.observeOperationFinished(finished)
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(fixture.coordinator.session.phase, .failed)
        XCTAssertEqual(fixture.resources.counts.value.pumped, 0)
        XCTAssertEqual(fixture.resources.counts.value.closed, 1)
        XCTAssertEqual(fixture.coordinator.microphone.state, .closed)
    }
    @MainActor func testCancellationAllocationFailureDoesNotAdmitActualCoordinator() throws {
        let fixture = try CoordinatorFixture()
        fixture.throwCancellationAllocation = true
        fixture.coordinator.start()
        XCTAssertEqual(fixture.coordinator.session.phase, .idle)
        XCTAssertFalse(fixture.coordinator.busy)
        XCTAssertEqual(fixture.coordinator.message, DictationError.inferenceFailed.localizedDescription)
        XCTAssertEqual(fixture.inference.counts.value.loads, 0)
        XCTAssertEqual(fixture.resources.counts.value.constructed, 0)
    }
    @MainActor func testCancelBeforeStartupTaskEntryNeverRequestsPermission() async throws {
        let fixture = try CoordinatorFixture()
        fixture.permissionStatus = .notDetermined
        // This uninterrupted MainActor turn is the entry barrier: the inherited startup
        // task cannot execute until the first await, after synchronous cancellation.
        fixture.coordinator.start()
        fixture.coordinator.cancel()
        let finished = expectation(description: "pre-entry cancellation drained")
        fixture.observeOperationFinished(finished)
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(fixture.permissionCalls, 0)
        XCTAssertFalse(fixture.permission.pending)
        XCTAssertEqual(fixture.resources.counts.value.constructed, 0)
        // Mutation cleanup only: a regression may have left the fake promise pending.
        if fixture.permission.pending {
            let cleaned = expectation(description: "injected regression cleanup")
            fixture.observeOperationFinished(cleaned)
            fixture.permission.resolve(false)
            await fulfillment(of: [cleaned], timeout: 2)
        }
    }
    @MainActor func testQuitCompletesWithUnansweredPermissionAndRejectsLateGrantedReply() async throws {
        let fixture = try CoordinatorFixture()
        fixture.permissionStatus = .notDetermined
        let asked = expectation(description: "fake permission promise awaiting answer")
        fixture.permission.requested = asked
        fixture.coordinator.start()
        await fulfillment(of: [asked], timeout: 2)
        let terminated = expectation(description: "quit independent of permission answer")
        fixture.terminated = terminated
        fixture.coordinator.quit()
        await fulfillment(of: [terminated], timeout: 2)
        XCTAssertTrue(fixture.permission.pending)
        XCTAssertEqual(fixture.inference.counts.value.loads, 0)
        XCTAssertEqual(fixture.resources.counts.value.constructed, 0)
        fixture.coordinator.quit() // permanent, idempotent shutdown admission.
        let finished = expectation(description: "late granted reply ignored")
        fixture.observeOperationFinished(finished)
        fixture.permission.resolve(true)
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(fixture.inference.counts.value.loads, 0)
        XCTAssertEqual(fixture.resources.counts.value.opened, 0)
        if fixture.terminationCalls == 0 {
            let cleanup = expectation(description: "injected shutdown regression cleanup")
            fixture.terminated = cleanup
            await fulfillment(of: [cleanup], timeout: 2)
        }
        XCTAssertEqual(fixture.terminationCalls, 1)
    }
    @MainActor func testQuitPermanentlyClosesStartAndImportAdmissionDuringDelayedUnload() async throws {
        let fixture = try CoordinatorFixture()
        let unloading = expectation(description: "shutdown reached fake unload")
        let gate = ControlledDelivery()
        fixture.inference.onUnload = unloading; fixture.inference.unloadGate = gate
        fixture.coordinator.quit()
        await fulfillment(of: [unloading], timeout: 2)
        await gate.waitUntilSuspended()
        XCTAssertTrue(fixture.coordinator.busy)
        XCTAssertFalse(fixture.coordinator.canStart)
        fixture.coordinator.importModel(); fixture.coordinator.start(); fixture.coordinator.unload()
        fixture.coordinator.quit()
        XCTAssertEqual(fixture.pickerCalls, 0)
        XCTAssertEqual(fixture.inference.counts.value.loads, 0)
        XCTAssertEqual(fixture.inference.counts.value.unloads, 1)
        let terminated = expectation(description: "single termination after unload")
        fixture.terminated = terminated
        await gate.release()
        await fulfillment(of: [terminated], timeout: 2)
        XCTAssertEqual(fixture.terminationCalls, 1)
        XCTAssertTrue(fixture.coordinator.busy)
    }
    @MainActor func testQuitDrainsAlreadyAdmittedModelWorkBeforeUnload() async throws {
        let fixture = try CoordinatorFixture()
        let loading = expectation(description: "fake model resource work admitted")
        let gate = ControlledDelivery()
        fixture.inference.onLoad = loading; fixture.inference.loadGate = gate
        fixture.coordinator.start()
        await fulfillment(of: [loading], timeout: 2)
        await gate.waitUntilSuspended()
        let drainReached = expectation(description: "Quit actor reached admitted-work await")
        let settled = expectation(description: "admitted model operation settled")
        let terminated = expectation(description: "resource work drained then unloaded")
        fixture.quitWillAwaitAdmittedOperation = drainReached
        fixture.observeAdmittedWorkSettled(settled)
        fixture.terminated = terminated
        fixture.coordinator.quit()
        // This resumes on MainActor only after the Quit job yields. Without the drain,
        // synchronous observation B must already be present, regardless of when the
        // nonisolated fake unload starts. Capture-cancel acknowledgment is not this barrier.
        await fulfillment(of: [drainReached], timeout: 2)
        XCTAssertEqual(fixture.quitTrace, [.willAwaitAdmittedOperation],
            "Quit reached inference unload before admitted model work settled")
        XCTAssertEqual(fixture.inference.counts.value.unloads, 0)
        XCTAssertEqual(fixture.terminationCalls, 0)
        await gate.release()
        // Drain both paths even under mutation so no held promise outlives the fixture.
        await fulfillment(of: [settled, terminated], timeout: 2)
        XCTAssertEqual(fixture.quitTrace, [.willAwaitAdmittedOperation, .admittedWorkSettled,
            .willUnloadInference, .unloadCompleted, .terminationRequested])
        XCTAssertEqual(fixture.inference.counts.value.unloads, 1)
        XCTAssertEqual(fixture.resources.counts.value.constructed, 0)
        fixture.coordinator.quit()
        XCTAssertEqual(fixture.terminationCalls, 1)
    }
    @MainActor func testConfigureHotkeyAfterQuitDoesNotRegister() async throws {
        let fixture = try CoordinatorFixture()
        fixture.coordinator.holdToTalk = false
        fixture.coordinator.selectDevelopmentShortcut(.commandShiftSpace)
        fixture.coordinator.setHotkeyEnabled(true)
        let registration = try XCTUnwrap(fixture.hotkeyRegistrar.registrations.first)
        XCTAssertEqual(fixture.hotkeyRegistrar.shortcuts, [.commandShiftSpace])
        XCTAssertEqual(registration.unregisterCalls, 0)

        let unloading = expectation(description: "Quit unload held for hotkey reconfiguration")
        let terminated = expectation(description: "hotkey teardown Quit completed")
        let gate = ControlledDelivery()
        fixture.inference.onUnload = unloading; fixture.inference.unloadGate = gate
        fixture.terminated = terminated
        fixture.coordinator.quit()
        // Admission closes synchronously, before the spawned Quit task can run.
        fixture.coordinator.configureHotkey()
        XCTAssertEqual(fixture.hotkeyRegistrar.registrations.count, 1,
            "Hotkey registered after Quit closed admission")
        XCTAssertEqual(registration.unregisterCalls, 1)
        await fulfillment(of: [unloading], timeout: 2)
        await gate.waitUntilSuspended()
        fixture.coordinator.configureHotkey()
        XCTAssertEqual(fixture.hotkeyRegistrar.registrations.count, 1,
            "Hotkey registered while Quit awaited unload")
        XCTAssertTrue(fixture.coordinator.hotkeyEnabled)
        XCTAssertFalse(fixture.coordinator.holdToTalk)
        XCTAssertEqual(fixture.coordinator.developmentShortcut, .commandShiftSpace)
        await gate.release()
        await fulfillment(of: [terminated], timeout: 2)
        XCTAssertEqual(fixture.terminationCalls, 1)
    }
    @MainActor func testRepeatedHotkeyEnableCommandRegistersOnce() throws {
        let fixture = try CoordinatorFixture()
        fixture.coordinator.setHotkeyEnabled(true)
        fixture.coordinator.setHotkeyEnabled(true)
        XCTAssertEqual(fixture.hotkeyRegistrar.registrations.count, 1)
        XCTAssertEqual(fixture.hotkeyRegistrar.registrations.first?.unregisterCalls, 0)
        fixture.coordinator.setHotkeyEnabled(false)
        fixture.coordinator.setHotkeyEnabled(false)
        XCTAssertEqual(fixture.hotkeyRegistrar.registrations.count, 1)
        XCTAssertEqual(fixture.hotkeyRegistrar.registrations.first?.unregisterCalls, 1)
    }

    @MainActor func testHotkeyEnableCommandAfterQuitCannotChangeSetting() async throws {
        let fixture = try CoordinatorFixture()
        let terminated = expectation(description: "Quit settled before late UI command")
        fixture.terminated = terminated
        fixture.coordinator.quit()
        fixture.coordinator.setHotkeyEnabled(true)
        XCTAssertFalse(fixture.coordinator.hotkeyEnabled)
        XCTAssertTrue(fixture.hotkeyRegistrar.registrations.isEmpty)
        await fulfillment(of: [terminated], timeout: 2)
    }

    @MainActor func testConfigureHotkeyDisabledUnregistersWithoutNewRegistration() throws {
        let fixture = try CoordinatorFixture()
        fixture.coordinator.setHotkeyEnabled(true)
        let registration = try XCTUnwrap(fixture.hotkeyRegistrar.registrations.first)
        fixture.coordinator.setHotkeyEnabled(false)
        fixture.coordinator.configureHotkey()
        XCTAssertEqual(registration.unregisterCalls, 1)
        XCTAssertEqual(fixture.hotkeyRegistrar.registrations.count, 1)
    }
}
