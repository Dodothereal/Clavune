import AVFoundation
import Foundation
import XCTest
@testable import ClavuneApp
@testable import ClavuneCore

/// Actual coordinator, synthetic picker/read/model boundaries. No system panel or audio.
final class AudioFileCoordinatorTests: UIFixtureAssertions {
    private let selected = URL(fileURLWithPath: "/synthetic-audio-never-opened.wav")
    private final class HeldRead: @unchecked Sendable {
        let entered: XCTestExpectation
        private let gate = DispatchSemaphore(value: 0)
        init(_ entered: XCTestExpectation) { self.entered = entered }
        func read() -> SessionPCM { entered.fulfill(); gate.wait(); return SessionPCM(samples: [0, 0.25, -0.25]) }
        func release() { gate.signal() }
    }
    @MainActor private func fixture(read: @escaping @Sendable () throws -> SessionPCM = { SessionPCM(samples: [0, 0.25, -0.25]) }) throws -> CoordinatorFixture {
        let url = selected
        return try CoordinatorFixture(configureEnvironment: { environment in
            environment.chooseAudioToImport = { _ in url }
            environment.readAudio = { _, _ in try read() }
        })
    }
    @MainActor func testImportReachesExistingModelAndReviewWithoutMicrophonePermissionOrWatchdog() async throws {
        let fixture = try fixture()
        fixture.permissionStatus = .denied
        fixture.coordinator.language = .de
        fixture.coordinator.importAudio(); await waitForOperation(fixture)
        XCTAssertEqual(fixture.coordinator.session.phase, .review)
        XCTAssertEqual(fixture.coordinator.editedText, fixture.inference.transcript)
        XCTAssertEqual(fixture.coordinator.session.rawTranscript, fixture.inference.transcript)
        XCTAssertEqual(fixture.coordinator.metrics?.frames16k, 3)
        XCTAssertNil(fixture.coordinator.metrics?.firstSample)
        XCTAssertTrue(fixture.coordinator.audioFileSession)
        XCTAssertEqual(fixture.inference.receivedPCM.value, [0, 0.25, -0.25])
        XCTAssertEqual(fixture.inference.receivedLanguage.value, .de)
        XCTAssertEqual(fixture.inference.counts.value.loads, 1)
        XCTAssertEqual(fixture.inference.counts.value.decodes, 1)
        XCTAssertEqual(fixture.resources.counts.value.constructed, 0)
        XCTAssertEqual(fixture.permissionCalls, 0)
        XCTAssertEqual(fixture.coordinator.microphone.state, .closed)
        XCTAssertTrue(fixture.watchdog.handles.isEmpty)
        XCTAssertTrue(fixture.clipboard.calls.isEmpty)
        XCTAssertTrue(fixture.coordinator.canSaveTranscript)
        XCTAssertFalse(fixture.coordinator.canImportAudio)
    }
    @MainActor func testPendingReviewEvenEmptyMustBeDiscardedBeforePickerOrAudioRead() async throws {
        var panels = 0
        let reads = FixtureValue(0), url = selected
        let fixture = try CoordinatorFixture(configureEnvironment: { environment in
            environment.chooseAudioToImport = { _ in panels += 1; return url }
            environment.readAudio = { _, _ in reads.update { $0 += 1 }; return SessionPCM(samples: [0]) }
        })
        await startRecording(fixture); await stopToReview(fixture)
        let id = fixture.coordinator.session.id, raw = fixture.coordinator.session.rawTranscript
        let metricID = fixture.coordinator.metrics?.session
        for text in ["unsaved draft", ""] {
            fixture.coordinator.editedText = text
            fixture.coordinator.importAudio()
            XCTAssertEqual(fixture.coordinator.session.id, id)
            XCTAssertEqual(fixture.coordinator.session.rawTranscript, raw)
            XCTAssertEqual(fixture.coordinator.editedText, text)
            XCTAssertEqual(fixture.coordinator.metrics?.session, metricID)
        }
        XCTAssertEqual(panels, 0); XCTAssertEqual(reads.value, 0)
        fixture.coordinator.discard(); XCTAssertTrue(fixture.coordinator.canImportAudio)
        fixture.coordinator.importAudio(); await waitForOperation(fixture)
        XCTAssertEqual(panels, 1); XCTAssertEqual(reads.value, 1)
        XCTAssertNotEqual(fixture.coordinator.session.id, id)
    }
    @MainActor func testMissingModelBusyAndPresentationQARejectAudioPicker() async throws {
        var panels = 0
        let configure: @MainActor (inout CoordinatorEnvironment) -> Void = { environment in
            environment.chooseAudioToImport = { _ in panels += 1; return nil }
        }
        let missing = try CoordinatorFixture(modelSelectionEnabled: false, configureEnvironment: configure)
        missing.coordinator.importAudio(); XCTAssertFalse(missing.coordinator.canImportAudio)
        let busy = try CoordinatorFixture(configureEnvironment: configure)
        await startRecording(busy); busy.coordinator.importAudio(); await cancelAndDrain(busy)
        let qa = try CoordinatorFixture(launchConfiguration: AppLaunchConfiguration.parse(environment: ["CLAVUNE_QA_PROFILE": "audio-import"]), configureEnvironment: configure)
        qa.coordinator.importAudio(); XCTAssertFalse(qa.coordinator.canImportAudio)
        XCTAssertEqual(panels, 0)
    }
    @MainActor func testPickerCancelAndAllocationFailureStartNoReadOrModelWork() async throws {
        var url: URL?
        let reads = FixtureValue(0)
        let fixture = try CoordinatorFixture(configureEnvironment: { environment in
            environment.chooseAudioToImport = { _ in url }
            environment.readAudio = { _, _ in reads.update { $0 += 1 }; return SessionPCM(samples: [0]) }
        })
        let before = fixture.coordinator.message
        fixture.coordinator.importAudio()
        XCTAssertEqual(fixture.coordinator.message, before)
        XCTAssertEqual(fixture.cancellationAllocationCalls, 0)
        url = selected; fixture.throwCancellationAllocation = true
        fixture.coordinator.importAudio()
        XCTAssertEqual(fixture.coordinator.session.phase, .idle)
        XCTAssertFalse(fixture.coordinator.busy)
        XCTAssertEqual(reads.value, 0)
        XCTAssertEqual(fixture.inference.counts.value.loads, 0)
    }
    @MainActor func testNestedPickerCommandsAndCancelCannotAdmitAnyResources() async throws {
        var owner: AppCoordinator?, panels = 0
        let reads = FixtureValue(0), url = selected
        let fixture = try CoordinatorFixture(configureEnvironment: { environment in
            environment.chooseAudioToImport = { _ in
                panels += 1
                owner?.importAudio(); owner?.start(); owner?.openTranscript(); owner?.importModel()
                owner?.cancel(); return url
            }
            environment.readAudio = { _, _ in reads.update { $0 += 1 }; return SessionPCM(samples: [0]) }
        })
        owner = fixture.coordinator
        fixture.coordinator.importAudio()
        XCTAssertEqual(panels, 1); XCTAssertEqual(reads.value, 0)
        XCTAssertEqual(fixture.cancellationAllocationCalls, 0)
        XCTAssertEqual(fixture.resources.counts.value.constructed, 0)
        XCTAssertFalse(fixture.coordinator.busy)
    }
    @MainActor func testQuitOrCancelInsideAudioPickerRejectsItsLateURLBeforeAnyRead() async throws {
        for shouldQuit in [false, true] {
            var owner: AppCoordinator?, pickers = 0, confirmations = 0
            let selected = selected, reads = FixtureValue(0)
            let fixture = try CoordinatorFixture(configureEnvironment: { environment in
                environment.chooseAudioToImport = { _ in
                    pickers += 1
                    if shouldQuit { owner?.quit() } else { owner?.cancel() }
                    return selected
                }
                environment.readAudio = { _, _ in
                    reads.update { $0 += 1 }
                    return SessionPCM(samples: [0])
                }
                environment.confirmUnsavedReviewQuit = { _ in confirmations += 1; return .save }
            })
            owner = fixture.coordinator
            if shouldQuit { fixture.terminated = expectation(description: "Quit after audio picker") }

            fixture.coordinator.importAudio()
            if shouldQuit { await fulfillment(of: [try XCTUnwrap(fixture.terminated)], timeout: 2) }

            XCTAssertEqual(pickers, 1)
            XCTAssertEqual(confirmations, 0, "No review means Quit never enters QuitSave")
            XCTAssertEqual(reads.value, 0, "The picker URL lost admission during its modal call")
            XCTAssertEqual(fixture.cancellationAllocationCalls, 0)
            XCTAssertEqual(fixture.inference.counts.value.loads, 0)
            XCTAssertEqual(fixture.inference.counts.value.decodes, 0)
            XCTAssertNotEqual(fixture.coordinator.session.phase, .review)
            XCTAssertNil(fixture.coordinator.session.id)
            XCTAssertNil(fixture.coordinator.metrics)
            XCTAssertFalse(fixture.coordinator.audioFilePending)
            XCTAssertFalse(fixture.coordinator.operationPending)
            XCTAssertEqual(fixture.coordinator.microphone.state, .closed)
            XCTAssertEqual(fixture.terminationCalls, shouldQuit ? 1 : 0)
        }
    }
    @MainActor func testHoldHotkeyReleaseDuringImportCannotCancelUnstartedRecording() async throws {
        let entered = expectation(description: "read held for shortcut")
        let read = HeldRead(entered), fixture = try fixture { read.read() }
        fixture.coordinator.setHotkeyEnabled(true)
        let registration = try XCTUnwrap(fixture.hotkeyRegistrar.registrations.last)
        fixture.coordinator.importAudio(); await fulfillment(of: [entered], timeout: 2)
        let id = fixture.coordinator.session.id
        registration.send(down: true); registration.send(down: false)
        fixture.coordinator.stop() // Stale/direct commands also obey the same guard.
        XCTAssertEqual(fixture.coordinator.session.id, id)
        XCTAssertEqual(fixture.coordinator.session.phase, .preparing)
        XCTAssertTrue(fixture.coordinator.audioFilePending)
        XCTAssertFalse(fixture.coordinator.canStop, "Stop must be unavailable during file preparation")
        XCTAssertEqual(fixture.resources.counts.value.constructed, 0)
        read.release(); await waitForOperation(fixture)
        XCTAssertEqual(fixture.coordinator.session.id, id)
        XCTAssertEqual(fixture.coordinator.session.phase, .review)
        XCTAssertEqual(fixture.coordinator.editedText, fixture.inference.transcript)
        XCTAssertEqual(fixture.inference.counts.value.decodes, 1)
    }
    @MainActor func testReadFailureGivesFileGuidanceWithoutLoadingModelAndAllowsExplicitRetry() async throws {
        let fail = FixtureValue(true)
        let fixture = try fixture {
            if fail.value { throw AudioFileImporter.Failure.durationLimit }
            return SessionPCM(samples: [0])
        }
        fixture.coordinator.importAudio(); await waitForOperation(fixture)
        XCTAssertEqual(fixture.coordinator.session.phase, .failed)
        XCTAssertTrue(fixture.coordinator.message.contains("M4A (AAC-LC/ALAC), AAC-LC, MP3 oder PCM-WAV"))
        XCTAssertNil(fixture.coordinator.dictationRecovery, "Do not suggest microphone fixes for file failures")
        XCTAssertEqual(DictationView(coordinator: fixture.coordinator).guidanceMode, .audioImportFailure,
                       "A failed file session must show file guidance instead of microphone-ready copy")
        XCTAssertEqual(fixture.inference.counts.value.loads, 0)
        XCTAssertTrue(fixture.coordinator.canImportAudio)
        fail.value = false
        fixture.coordinator.importAudio(); await waitForOperation(fixture)
        XCTAssertEqual(fixture.coordinator.session.phase, .review)
    }
    @MainActor func testInvalidSelectedModelRecoveryOutranksPriorFileFailureGuidance() async throws {
        let fixture = try fixture { throw AudioFileImporter.Failure.durationLimit }
        fixture.coordinator.importAudio(); await waitForOperation(fixture)
        XCTAssertEqual(DictationView(coordinator: fixture.coordinator).guidanceMode, .audioImportFailure)

        // The fixture's local model verifier rejects the selected file. The
        // old file-retry guidance would now suggest an action that is disabled.
        fixture.coordinator.checkInstalledModels(); await waitForOperation(fixture)
        XCTAssertTrue(fixture.coordinator.selectedModelNeedsRevalidation)
        XCTAssertFalse(fixture.coordinator.canImportAudio)
        XCTAssertEqual(DictationView(coordinator: fixture.coordinator).guidanceMode, .selectedModelUnavailable)
    }
    @MainActor func testModelAndDecoderFailuresUseFileGuidanceNotMicrophoneRecovery() async throws {
        for atLoad in [true, false] {
            let fixture = try fixture()
            if atLoad { fixture.inference.loadFailure = .modelInvalid }
            else { fixture.inference.decodeFailure = .inferenceFailed }
            fixture.coordinator.importAudio(); await waitForOperation(fixture)
            XCTAssertEqual(fixture.coordinator.session.phase, .failed)
            XCTAssertEqual(fixture.coordinator.message,
                "Lokale Datei-Transkription fehlgeschlagen. Modell prüfen und die Datei bewusst erneut importieren.")
            XCTAssertNil(fixture.coordinator.dictationRecovery)
            XCTAssertEqual(DictationView(coordinator: fixture.coordinator).guidanceMode, .audioImportFailure,
                           "Read, model, and decoder failures share the file-specific recovery presentation")
            XCTAssertTrue(fixture.coordinator.canImportAudio)
        }
    }
    @MainActor func testCancelAndPrivacyDuringReadHoldAdmissionUntilDrainAndRejectLatePCM() async throws {
        for privacy in [false, true] {
            let entered = expectation(description: "audio read entered")
            // Each reader has one bounded synthetic suspension, released before leaving the test.
            let read = HeldRead(entered)
            let fixture = try fixture { read.read() }
            fixture.coordinator.importAudio(); await fulfillment(of: [entered], timeout: 2)
            if privacy { fixture.coordinator.interruptForPrivacy() } else { fixture.coordinator.cancel() }
            XCTAssertTrue(fixture.coordinator.audioFilePending)
            XCTAssertTrue(fixture.coordinator.operationPending)
            XCTAssertFalse(fixture.coordinator.canStart)
            XCTAssertEqual(DictationView(coordinator: fixture.coordinator).guidanceMode, .hidden)
            fixture.coordinator.importAudio(); fixture.coordinator.start(); fixture.coordinator.openTranscript()
            read.release(); await waitForOperation(fixture)
            XCTAssertFalse(fixture.coordinator.audioFilePending)
            XCTAssertEqual(fixture.coordinator.session.phase, .cancelled)
            XCTAssertEqual(DictationView(coordinator: fixture.coordinator).guidanceMode, .audioImportCancelled,
                           "Interrupted file import must not show microphone-ready instructions after drain")
            XCTAssertEqual(fixture.inference.counts.value.loads, 0)
            XCTAssertEqual(fixture.inference.counts.value.decodes, 0)
            XCTAssertEqual(fixture.resources.counts.value.constructed, 0)
            XCTAssertEqual(fixture.coordinator.editedText, "")
            XCTAssertTrue(fixture.coordinator.canImportAudio)
        }
    }
    @MainActor func testCancelDuringModelLoadAndDecodeRejectsLateResultUntilWorkerDrain() async throws {
        for atLoad in [true, false] {
            let fixture = try fixture(), gate = ControlledDelivery()
            let entered = expectation(description: "inference resource entered")
            if atLoad { fixture.inference.onLoad = entered; fixture.inference.loadGate = gate }
            else { fixture.inference.onDecode = entered; fixture.inference.decodeGate = gate }
            fixture.coordinator.importAudio(); await fulfillment(of: [entered], timeout: 2)
            await gate.waitUntilSuspended()
            fixture.coordinator.cancel()
            XCTAssertTrue(fixture.coordinator.audioFilePending)
            XCTAssertFalse(fixture.coordinator.canImportAudio)
            XCTAssertEqual(DictationView(coordinator: fixture.coordinator).guidanceMode, .hidden)
            await gate.release(); await waitForOperation(fixture)
            XCTAssertEqual(fixture.coordinator.session.phase, .cancelled)
            XCTAssertEqual(DictationView(coordinator: fixture.coordinator).guidanceMode, .audioImportCancelled)
            XCTAssertEqual(fixture.coordinator.editedText, "")
            XCTAssertEqual(fixture.inference.counts.value.decodes, atLoad ? 0 : 1)
            XCTAssertTrue(fixture.coordinator.canStart)
        }
    }
    @MainActor func testQuitWaitsForReadDrainBeforeUnloadAndTermination() async throws {
        let entered = expectation(description: "read entered")
        let read = HeldRead(entered), fixture = try fixture { read.read() }
        fixture.coordinator.importAudio(); await fulfillment(of: [entered], timeout: 2)
        let reached = expectation(description: "quit await reached"), settled = expectation(description: "read settled")
        let terminated = expectation(description: "terminated after drain")
        fixture.quitWillAwaitAdmittedOperation = reached; fixture.terminated = terminated
        fixture.observeAdmittedWorkSettled(settled)
        fixture.coordinator.quit(); fixture.coordinator.quit()
        await fulfillment(of: [reached], timeout: 2)
        XCTAssertEqual(fixture.quitTrace, [.willAwaitAdmittedOperation])
        XCTAssertEqual(fixture.inference.counts.value.unloads, 0)
        read.release(); await fulfillment(of: [settled, terminated], timeout: 2)
        XCTAssertEqual(fixture.quitTrace, [.willAwaitAdmittedOperation, .admittedWorkSettled,
                                          .willUnloadInference, .unloadCompleted, .terminationRequested])
        XCTAssertEqual(fixture.terminationCalls, 1)
        XCTAssertEqual(fixture.coordinator.editedText, "")
        XCTAssertFalse(fixture.coordinator.audioFilePending)
    }
    @MainActor func testImportTimingsIncludeFilePreparationAndModelWaitBeforeResult() async throws {
        let readEntered = expectation(description: "read admitted")
        let read = HeldRead(readEntered), fixture = try fixture { read.read() }
        let modelEntered = expectation(description: "model admitted"), gate = ControlledDelivery()
        fixture.inference.onLoad = modelEntered; fixture.inference.loadGate = gate
        fixture.now = 100
        fixture.coordinator.importAudio(); await fulfillment(of: [readEntered], timeout: 2)
        XCTAssertNil(fixture.coordinator.metrics?.audioPreparationSeconds)
        XCTAssertNil(fixture.coordinator.metrics?.audioImportTotalSeconds)
        fixture.now = 300; read.release()
        await fulfillment(of: [modelEntered], timeout: 2); await gate.waitUntilSuspended()
        XCTAssertEqual(fixture.coordinator.metrics?.audioPreparationSeconds,
                       AVAudioTime.seconds(forHostTime: 200))
        XCTAssertNil(fixture.coordinator.metrics?.audioImportTotalSeconds)
        fixture.now = 700; await gate.release(); await waitForOperation(fixture)
        XCTAssertEqual(fixture.coordinator.metrics?.audioImportTotalSeconds,
                       AVAudioTime.seconds(forHostTime: 600))
        XCTAssertEqual(fixture.coordinator.metrics?.decodeSeconds, 0, "Model stub time is not total import latency")
        XCTAssertEqual(fixture.coordinator.session.phase, .review)
    }
    @MainActor func testDiscardImportedReviewAllowsNewRecordingAndResetsFileGuidance() async throws {
        let fixture = try fixture()
        fixture.coordinator.importAudio(); await waitForOperation(fixture)
        fixture.coordinator.discard()
        XCTAssertFalse(fixture.coordinator.audioFileSession)
        await startRecording(fixture); await cancelAndDrain(fixture)
        XCTAssertFalse(fixture.coordinator.audioFileSession)
    }
}
