import XCTest
@testable import ClavuneApp
@testable import ClavuneCore

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
        fixture.coordinator.quit()
        XCTAssertEqual(fixture.inference.counts.value.unloads, 0)
        XCTAssertEqual(fixture.terminationCalls, 0)
        let terminated = expectation(description: "resource work drained then unloaded")
        fixture.terminated = terminated
        await gate.release()
        await fulfillment(of: [terminated], timeout: 2)
        XCTAssertEqual(fixture.inference.counts.value.unloads, 1)
        XCTAssertEqual(fixture.resources.counts.value.constructed, 0)
    }
}
