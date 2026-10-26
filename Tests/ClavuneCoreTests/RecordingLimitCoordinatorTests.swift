import XCTest
@testable import ClavuneApp
@testable import ClavuneCore

final class RecordingLimitCoordinatorTests: XCTestCase {
    @MainActor private func startRecording(_ fixture: CoordinatorFixture) async throws -> UUID {
        let recording = expectation(description: "recording")
        let settled = expectation(description: "startup settled")
        fixture.coordinator.start()
        fixture.observePhase(.recording, expectation: recording)
        fixture.observeOperationFinished(settled)
        await fulfillment(of: [recording, settled], timeout: 2)
        return try XCTUnwrap(fixture.coordinator.session.id)
    }
    @MainActor private func awaitReview(_ fixture: CoordinatorFixture) async {
        let review = expectation(description: "limit review")
        fixture.observePhase(.review, expectation: review)
        await fulfillment(of: [review], timeout: 2)
        let settled = expectation(description: "transcription settled")
        fixture.observeOperationFinished(settled)
        await fulfillment(of: [settled], timeout: 2)
    }
    @MainActor func testAutomaticLimitClosesOnceAndDeliversExistingTranscriptionReview() async throws {
        let fixture = try CoordinatorFixture()
        let id = try await startRecording(fixture)
        fixture.resources.reachLimit(session: id, cutoff: 120_000)
        await awaitReview(fixture)
        XCTAssertEqual(fixture.resources.counts.value.closed, 1)
        XCTAssertEqual(fixture.resources.counts.value.stopCutoffs, [120_000])
        XCTAssertEqual(fixture.inference.counts.value.decodes, 1)
        XCTAssertEqual(fixture.inference.receivedPCM.value, [0.1, 0.2])
        XCTAssertEqual(fixture.coordinator.metrics?.requestedStop, 120_000)
        XCTAssertEqual(fixture.coordinator.metrics?.frames16k, 2)
        XCTAssertEqual(fixture.coordinator.microphone.state, .closed)
        XCTAssertTrue(fixture.coordinator.message.contains("Sitzungslimit erreicht"))
        XCTAssertEqual(fixture.coordinator.editedText, fixture.inference.transcript)
        XCTAssertTrue(fixture.coordinator.hasPendingReview)
        XCTAssertFalse(fixture.coordinator.canStart)
    }
    @MainActor func testLimitWithoutFirstSampleCallbackCompletesAcrossStartupOrdering() async throws {
        let fixture = try CoordinatorFixture()
        fixture.resources.automaticallyDeliverFirstSample = false
        fixture.resources.limitOnBegin = 120_000
        fixture.coordinator.start()
        await awaitReview(fixture)
        XCTAssertEqual(fixture.inference.counts.value.decodes, 1)
        XCTAssertEqual(fixture.resources.counts.value.closed, 1)
        XCTAssertFalse(fixture.coordinator.busy)
        XCTAssertEqual(fixture.coordinator.microphone.state, .closed)
    }
    @MainActor func testLimitDeliveredBeforeStartupResumeIsDeferredUntilAdmissionDrains() async throws {
        let lifecycle = FixtureProgressDispatcher()
        let releaseStart = DispatchSemaphore(value: 0)
        let timedOut = FixtureValue(false)
        let fixture = try CoordinatorFixture(configureEnvironment: { environment in
            environment.dispatchCaptureLifecycle = { work in
                lifecycle.dispatch { work(); releaseStart.signal() }
            }
        })
        fixture.resources.automaticallyDeliverFirstSample = false
        fixture.resources.limitOnBegin = 120_000
        // Test-only control-queue barrier: startup cannot resume until the actual
        // coordinator limit callback has returned. No timer/FIFO assumption.
        fixture.resources.duringLimitOnBegin = {
            timedOut.value = releaseStart.wait(timeout: .now() + 2) == .timedOut
        }
        fixture.coordinator.start()
        await awaitReview(fixture)
        for submission in lifecycle.takeSubmissions() { await submission.task.value }
        XCTAssertFalse(timedOut.value)
        XCTAssertEqual(fixture.inference.counts.value.decodes, 1)
        XCTAssertEqual(fixture.resources.counts.value.stopCutoffs, [120_000])
        XCTAssertFalse(fixture.coordinator.operationPending)
    }
    @MainActor func testDuplicateLimitAndLateCallbacksCannotRestartDecodeOrReplaceReview() async throws {
        let fixture = try CoordinatorFixture()
        let id = try await startRecording(fixture)
        let gate = ControlledDelivery()
        fixture.inference.decodeGate = gate
        let decoding = expectation(description: "limit decode entered")
        fixture.inference.onDecode = decoding
        fixture.resources.reachLimit(session: id, cutoff: 120_000)
        await fulfillment(of: [decoding], timeout: 2)
        guard fixture.inference.counts.value.decodes == 1 else { fixture.coordinator.cancel(); return }
        await gate.waitUntilSuspended()
        let callbacks = try XCTUnwrap(fixture.resources.callbacks.value[id])
        callbacks.limit(CaptureStopRequest(session: id, cutoffHostTime: 120_000))
        callbacks.failure(.overflow); callbacks.first(); callbacks.progress(125, 1)
        for submission in fixture.lifecycleDispatcher.takeSubmissions() { await submission.task.value }
        await gate.release()
        await awaitReview(fixture)
        // Fault-inject duplicates again after final review; these do not run service logic.
        callbacks.limit(CaptureStopRequest(session: id, cutoffHostTime: 120_000))
        callbacks.failure(.discontinuity); callbacks.first(); callbacks.progress(126, 1)
        let progress = fixture.progressDispatcher.takeSubmissions()
        for submission in progress { await submission.task.value }
        for submission in fixture.lifecycleDispatcher.takeSubmissions() { await submission.task.value }
        XCTAssertEqual(fixture.inference.counts.value.decodes, 1)
        XCTAssertEqual(fixture.resources.counts.value.stopCutoffs, [120_000])
        XCTAssertEqual(fixture.coordinator.session.phase, .review)
        XCTAssertEqual(fixture.coordinator.editedText, fixture.inference.transcript)
        XCTAssertEqual(fixture.coordinator.microphone.state, .closed)
    }
    @MainActor func testCancelWinsWhileLimitDecodeIsPendingAndLateResultCannotReappear() async throws {
        let fixture = try CoordinatorFixture()
        let id = try await startRecording(fixture)
        let gate = ControlledDelivery(); fixture.inference.decodeGate = gate
        let decoding = expectation(description: "limit decode entered before cancellation")
        fixture.inference.onDecode = decoding
        fixture.resources.reachLimit(session: id, cutoff: 120_000)
        await fulfillment(of: [decoding], timeout: 2)
        guard fixture.inference.counts.value.decodes == 1 else { fixture.coordinator.cancel(); return }
        await gate.waitUntilSuspended()
        fixture.coordinator.cancel()
        let closed = expectation(description: "cancel acknowledged")
        fixture.observeCloseFinished(closed)
        await fulfillment(of: [closed], timeout: 2)
        XCTAssertTrue(fixture.coordinator.operationPending)
        fixture.resources.callbacks.value[id]?.limit(CaptureStopRequest(session: id, cutoffHostTime: 120_000))
        await gate.release()
        let settled = expectation(description: "cancelled decode drained")
        fixture.observeOperationFinished(settled)
        await fulfillment(of: [settled], timeout: 2)
        XCTAssertEqual(fixture.coordinator.session.phase, .cancelled)
        XCTAssertTrue(fixture.coordinator.editedText.isEmpty)
        XCTAssertEqual(fixture.coordinator.microphone.state, .closed)
        XCTAssertEqual(fixture.inference.counts.value.decodes, 1)
    }
    @MainActor func testCancelBeforeQueuedLimitDeliveryNeverStartsInference() async throws {
        let fixture = try CoordinatorFixture()
        let id = try await startRecording(fixture)
        // Both callbacks enqueue MainActor tasks; this actor turn cancels first.
        fixture.resources.callbacks.value[id]?.limit(CaptureStopRequest(session: id, cutoffHostTime: 120_000))
        fixture.coordinator.cancel()
        let closed = expectation(description: "cancel closed")
        fixture.observeCloseFinished(closed)
        await fulfillment(of: [closed], timeout: 2)
        XCTAssertEqual(fixture.inference.counts.value.decodes, 0)
        XCTAssertEqual(fixture.coordinator.session.phase, .cancelled)
        XCTAssertTrue(fixture.coordinator.editedText.isEmpty)
    }
    @MainActor func testGenuineOverflowRemainsFailureWithoutTranscription() async throws {
        let fixture = try CoordinatorFixture()
        let id = try await startRecording(fixture)
        let failed = expectation(description: "overflow failure")
        fixture.observePhase(.failed, expectation: failed)
        fixture.resources.fail(session: id, error: .overflow)
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertEqual(fixture.coordinator.session.failure, .overflow)
        XCTAssertEqual(fixture.inference.counts.value.decodes, 0)
        XCTAssertEqual(fixture.resources.counts.value.closed, 1)
        XCTAssertFalse(fixture.coordinator.message.contains("Sitzungslimit erreicht"))
    }
    @MainActor func testOldLimitCallbackCannotStopNewSession() async throws {
        let fixture = try CoordinatorFixture()
        let oldID = try await startRecording(fixture)
        fixture.coordinator.stop(); await awaitReview(fixture)
        fixture.coordinator.discard()
        let newID = try await startRecording(fixture)
        XCTAssertNotEqual(oldID, newID)
        fixture.resources.callbacks.value[oldID]?.limit(CaptureStopRequest(session: oldID, cutoffHostTime: 120_000))
        for submission in fixture.lifecycleDispatcher.takeSubmissions() { await submission.task.value }
        XCTAssertEqual(fixture.coordinator.session.phase, .recording)
        fixture.coordinator.stop(); await awaitReview(fixture)
        XCTAssertEqual(fixture.resources.counts.value.stopCutoffs, [100, 100])
        XCTAssertEqual(fixture.inference.counts.value.decodes, 2)
    }
}
