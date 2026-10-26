import XCTest
@testable import ClavuneApp
@testable import ClavuneCore

final class DictationRecoveryTests: XCTestCase {
    private let errors: [DictationError] = [
        .configuration, .permissionDenied, .privacyBlocked, .unsupportedFormat, .audioUnavailable,
        .overflow, .durationLimit, .discontinuity, .endpointUncertain, .noAudio,
        .modelMissing, .modelMismatch, .modelInvalid, .inferenceFailed, .cancelled, .busy
    ]

    func testEveryErrorHasLocalizedGuidanceAndModelErrorsDoNotOfferRecordingRetry() throws {
        let blocked: Set<DictationError> = [.configuration, .modelMissing, .modelMismatch,
            .modelInvalid, .busy, .cancelled]
        for error in errors {
            var session = SessionMachine()
            let id = try session.begin()
            session.fail(error, session: id)
            if error == .cancelled {
                XCTAssertNil(DictationRecovery(session: session), "Cancellation is not a failure")
                continue
            }
            let recovery = try XCTUnwrap(DictationRecovery(session: session))
            XCTAssertEqual(recovery.error, error)
            XCTAssertFalse(recovery.guidance.isEmpty)
            XCTAssertEqual(recovery.offersNewRecording, !blocked.contains(error))
            XCTAssertEqual(UILanguage.german.text(recovery.guidance), recovery.guidance)
            XCTAssertNotEqual(UILanguage.english.text(recovery.guidance), recovery.guidance)
        }
        XCTAssertEqual(UILanguage.english.text("Neu aufnehmen"), "Record again")
        XCTAssertEqual(UILanguage.english.text("Aufnahme nicht abgeschlossen"), "Recording was not completed")
    }

    func testRecoveryNeverAppearsForActiveReviewCancelledOrDiscardedSessions() throws {
        var session = SessionMachine()
        XCTAssertNil(DictationRecovery(session: session))
        let id = try session.begin()
        XCTAssertNil(DictationRecovery(session: session))
        session.recording(id)
        XCTAssertNil(DictationRecovery(session: session))
        session.stopping(id)
        XCTAssertNil(DictationRecovery(session: session))
        session.transcribing(id)
        XCTAssertNil(DictationRecovery(session: session))
        session.result("Synthetic review", session: id)
        XCTAssertNil(DictationRecovery(session: session))
        session.cancel()
        XCTAssertNil(DictationRecovery(session: session))
        session.discard()
        XCTAssertNil(DictationRecovery(session: session))
    }

    @MainActor private func failPermission(_ fixture: CoordinatorFixture) async {
        fixture.permissionStatus = .denied
        fixture.coordinator.start()
        let finished = expectation(description: "permission failure drained")
        fixture.observeOperationFinished(finished)
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(fixture.coordinator.session.failure, .permissionDenied)
        XCTAssertEqual(fixture.coordinator.microphone.state, .closed)
    }

    @MainActor private func finishReview(_ fixture: CoordinatorFixture) async {
        fixture.coordinator.stop()
        let reviewed = expectation(description: "synthetic review ready")
        let finished = expectation(description: "review operation drained")
        fixture.observePhase(.review, expectation: reviewed)
        fixture.observeOperationFinished(finished)
        await fulfillment(of: [reviewed, finished], timeout: 2)
    }

    @MainActor func testPermissionRecoveryStartsExactlyOneNewSessionAndKeepsRecognitionChoice() async throws {
        let fixture = try CoordinatorFixture()
        fixture.coordinator.language = .de
        await failPermission(fixture)
        let failedID = try XCTUnwrap(fixture.coordinator.session.id)
        XCTAssertNotNil(fixture.coordinator.dictationRecovery)
        XCTAssertEqual(DictationView(coordinator: fixture.coordinator).guidanceMode, .recovery,
                       "Microphone failures must keep their microphone-specific recovery presentation")
        XCTAssertTrue(fixture.coordinator.canRetryFailedRecording)
        XCTAssertEqual(fixture.resources.counts.value.opened, 0)
        fixture.permissionStatus = .authorized
        fixture.coordinator.retryFailedRecording()
        fixture.coordinator.retryFailedRecording() // A repeated click has no admission.
        XCTAssertNotEqual(fixture.coordinator.session.id, failedID)
        XCTAssertNil(fixture.coordinator.session.failure)
        XCTAssertNil(fixture.coordinator.dictationRecovery)
        XCTAssertFalse(fixture.coordinator.canRetryFailedRecording)
        let recording = expectation(description: "fresh recording")
        let started = expectation(description: "fresh start drained")
        fixture.observePhase(.recording, expectation: recording)
        fixture.observeOperationFinished(started)
        await fulfillment(of: [recording, started], timeout: 2)
        XCTAssertEqual(fixture.resources.counts.value.opened, 1)
        XCTAssertEqual(fixture.inference.counts.value.loads, 1)
        XCTAssertEqual(fixture.coordinator.language, .de)
        await finishReview(fixture)
    }

    @MainActor func testStaleRecoveryActionCannotEraseReviewOrStartFromIdle() async throws {
        let fixture = try CoordinatorFixture()
        fixture.coordinator.retryFailedRecording()
        XCTAssertEqual(fixture.coordinator.session.phase, .idle)
        XCTAssertEqual(fixture.cancellationAllocationCalls, 0)
        await failPermission(fixture)
        fixture.permissionStatus = .authorized
        fixture.coordinator.retryFailedRecording()
        let recording = expectation(description: "recording for review protection")
        let started = expectation(description: "start drained")
        fixture.observePhase(.recording, expectation: recording)
        fixture.observeOperationFinished(started)
        await fulfillment(of: [recording, started], timeout: 2)
        await finishReview(fixture)
        fixture.coordinator.editedText = "Synthetic edited review to preserve"
        let raw = fixture.coordinator.session.rawTranscript
        let id = fixture.coordinator.session.id
        let allocations = fixture.cancellationAllocationCalls
        fixture.coordinator.retryFailedRecording()
        XCTAssertEqual(fixture.coordinator.session.id, id)
        XCTAssertEqual(fixture.coordinator.session.phase, .review)
        XCTAssertEqual(fixture.coordinator.session.rawTranscript, raw)
        XCTAssertEqual(fixture.coordinator.editedText, "Synthetic edited review to preserve")
        XCTAssertEqual(fixture.cancellationAllocationCalls, allocations)
        XCTAssertEqual(fixture.resources.counts.value.opened, 1)
    }

    @MainActor func testRecoveryWaitsForAdmittedWorkAndRejectsActionAfterQuit() async throws {
        let fixture = try CoordinatorFixture()
        await failPermission(fixture)
        let failedID = fixture.coordinator.session.id
        let gate = ControlledDelivery()
        let unloading = expectation(description: "admitted unload waiting")
        fixture.inference.unloadGate = gate
        fixture.inference.onUnload = unloading
        fixture.coordinator.unload()
        await fulfillment(of: [unloading], timeout: 2)
        await gate.waitUntilSuspended()
        XCTAssertNotNil(fixture.coordinator.dictationRecovery)
        XCTAssertFalse(fixture.coordinator.canRetryFailedRecording)
        fixture.coordinator.retryFailedRecording()
        XCTAssertEqual(fixture.coordinator.session.id, failedID)
        XCTAssertEqual(fixture.inference.counts.value.loads, 0)
        XCTAssertEqual(fixture.resources.counts.value.opened, 0)
        let finished = expectation(description: "unload drained")
        fixture.observeOperationFinished(finished)
        await gate.release()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertTrue(fixture.coordinator.canRetryFailedRecording)
        fixture.inference.unloadGate = nil
        fixture.inference.onUnload = nil
        let terminated = expectation(description: "quit drained")
        fixture.terminated = terminated
        fixture.coordinator.quit()
        fixture.coordinator.retryFailedRecording()
        await fulfillment(of: [terminated], timeout: 2)
        XCTAssertFalse(fixture.coordinator.canRetryFailedRecording)
        XCTAssertEqual(fixture.inference.counts.value.loads, 0)
        XCTAssertEqual(fixture.resources.counts.value.opened, 0)
    }

    @MainActor func testFailedFreshAdmissionPreservesPriorFailureAndDoesNotTouchAudio() async throws {
        let fixture = try CoordinatorFixture()
        await failPermission(fixture)
        let failedID = fixture.coordinator.session.id
        fixture.throwCancellationAllocation = true
        fixture.coordinator.retryFailedRecording()
        XCTAssertEqual(fixture.coordinator.session.id, failedID)
        XCTAssertEqual(fixture.coordinator.session.failure, .permissionDenied)
        XCTAssertNotNil(fixture.coordinator.dictationRecovery)
        XCTAssertEqual(fixture.resources.counts.value.constructed, 0)
        XCTAssertEqual(fixture.inference.counts.value.loads, 0)
    }

    @MainActor func testMicrophoneModelLoadFailureRequiresExplicitModelRevalidation() async throws {
        let candidate = try XCTUnwrap(ModelStore.candidates().first)
        let shouldImportSucceed = FixtureValue(false)
        let replacementURL = URL(fileURLWithPath: "/fixture-revalidated-model")
        let fixture = try CoordinatorFixture(configureEnvironment: { environment in
            environment.importManagedModel = { _ in
                guard shouldImportSucceed.value else { throw DictationError.modelInvalid }
                return ModelStore.Installed(url: replacementURL, candidate: candidate)
            }
        })
        fixture.chooseModel = { URL(fileURLWithPath: "/fixture-model-source") }
        fixture.inference.loadFailure = .modelInvalid

        fixture.coordinator.start()
        let failedStart = expectation(description: "model-load failure drained")
        fixture.observeOperationFinished(failedStart)
        await fulfillment(of: [failedStart], timeout: 2)
        XCTAssertEqual(fixture.coordinator.session.failure, .modelInvalid)
        XCTAssertFalse(fixture.coordinator.canStart)
        XCTAssertFalse(fixture.coordinator.canImportAudio)
        XCTAssertFalse(fixture.coordinator.canRetryFailedRecording)

        fixture.coordinator.start()
        XCTAssertEqual(fixture.inference.counts.value.loads, 1,
                       "The disabled general Start path must not retry the failed model load")

        fixture.coordinator.importModel()
        let failedImport = expectation(description: "failed model re-import drained")
        fixture.observeOperationFinished(failedImport)
        await fulfillment(of: [failedImport], timeout: 2)
        XCTAssertFalse(fixture.coordinator.canStart,
                       "A failed model verification must leave microphone Start disabled")

        shouldImportSucceed.value = true
        fixture.coordinator.importModel()
        let verifiedImport = expectation(description: "verified model re-import drained")
        fixture.observeOperationFinished(verifiedImport)
        await fulfillment(of: [verifiedImport], timeout: 2)
        XCTAssertEqual(fixture.coordinator.session.phase, .idle,
                       "Successful verification clears the stale model-load recovery state")
        XCTAssertNil(fixture.coordinator.dictationRecovery)
        XCTAssertTrue(fixture.coordinator.canStart)

        fixture.inference.loadFailure = nil
        fixture.coordinator.start()
        let recording = expectation(description: "recording starts after model verification")
        let started = expectation(description: "verified-model startup drained")
        fixture.observePhase(.recording, expectation: recording)
        fixture.observeOperationFinished(started)
        await fulfillment(of: [recording, started], timeout: 2)
        XCTAssertEqual(fixture.inference.counts.value.loads, 2)
        XCTAssertEqual(fixture.resources.counts.value.opened, 1)
        await finishReview(fixture)
    }
}
