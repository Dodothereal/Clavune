import XCTest
@testable import ClavuneApp
@testable import ClavuneCore

final class WatchdogQueuedTickTests: UIFixtureAssertions {
    @MainActor func testCancelledTimerQueuedTickRevalidatesCurrentSessionInsteadOfResurrectingOldOne() async throws {
        let fixture = try CoordinatorFixture()
        await startRecording(fixture)
        let old = try XCTUnwrap(fixture.watchdog.handles.first)
        XCTAssertEqual(fixture.watchdog.activeCount, 1)
        await cancelAndDrain(fixture)
        XCTAssertEqual(old.cancellationCalls, 1)
        XCTAssertEqual(fixture.watchdog.activeCount, 0)
        let opened = fixture.resources.counts.value.opened
        old.deliverAlreadyQueuedTick()
        XCTAssertEqual(fixture.resources.counts.value.opened, opened)
        XCTAssertEqual(fixture.coordinator.session.phase, .cancelled)
        XCTAssertEqual(fixture.coordinator.microphone.state, .closed)
        XCTAssertFalse(fixture.coordinator.busy)

        await startRecording(fixture)
        let currentID = fixture.coordinator.session.id
        XCTAssertEqual(fixture.watchdog.handles.count, 2)
        XCTAssertEqual(fixture.watchdog.activeCount, 1)
        old.deliverAlreadyQueuedTick()
        XCTAssertEqual(fixture.coordinator.session.id, currentID)
        XCTAssertEqual(fixture.coordinator.session.phase, .recording,
            "A stale tick must not cancel a currently privacy-valid session")
        XCTAssertEqual(fixture.watchdog.activeCount, 1)
        fixture.permissionStatus = .denied
        old.deliverAlreadyQueuedTick()
        XCTAssertEqual(fixture.coordinator.session.phase, .cancelled,
            "An already-queued tick must still cancel current capture if current privacy is revoked")
        await cancelAndDrain(fixture)
        XCTAssertEqual(fixture.watchdog.activeCount, 0)
        XCTAssertEqual(fixture.watchdog.handles.map(\.cancellationCalls), [1, 1])
        XCTAssertEqual(fixture.resources.counts.value.closed, 2)
    }

    @MainActor func testWatchdogRemainsActiveDuringClosedMicrophoneDecodeAndStopsOnCancel() async throws {
        let fixture = try CoordinatorFixture()
        await startRecording(fixture)
        let tick = try XCTUnwrap(fixture.watchdog.handles.first)
        let decode = ControlledDelivery()
        let entered = expectation(description: "decode delayed after actual capture close")
        fixture.inference.decodeGate = decode; fixture.inference.onDecode = entered
        fixture.coordinator.stop()
        await fulfillment(of: [entered], timeout: 2)
        await decode.waitUntilSuspended()
        XCTAssertEqual(fixture.coordinator.session.phase, .transcribing)
        XCTAssertEqual(fixture.coordinator.microphone.state, .closed)
        XCTAssertEqual(fixture.watchdog.activeCount, 1,
            "Meter disappearance is not the watchdog lifetime boundary")
        tick.fireActiveTimer()
        XCTAssertEqual(fixture.coordinator.session.phase, .transcribing)
        fixture.privacy.value = false
        tick.deliverAlreadyQueuedTick()
        XCTAssertEqual(fixture.coordinator.session.phase, .cancelled)
        XCTAssertEqual(fixture.watchdog.activeCount, 0)
        await decode.release()
        await cancelAndDrain(fixture)
        tick.deliverAlreadyQueuedTick()
        XCTAssertEqual(fixture.coordinator.session.phase, .cancelled)
        XCTAssertEqual(fixture.coordinator.microphone.state, .closed)
        XCTAssertTrue(fixture.coordinator.session.rawTranscript.isEmpty)
        XCTAssertFalse(fixture.coordinator.busy)
        XCTAssertEqual(tick.cancellationCalls, 1)
    }

    @MainActor func testQueuedWatchdogAfterReviewAndDiscardDoesNotStartNewWork() async throws {
        let fixture = try CoordinatorFixture()
        await startRecording(fixture)
        let tick = try XCTUnwrap(fixture.watchdog.handles.first)
        await stopToReview(fixture)
        XCTAssertEqual(fixture.watchdog.activeCount, 0)
        let opened = fixture.resources.counts.value.opened
        let decoded = fixture.inference.counts.value.decodes
        fixture.privacy.value = false
        tick.deliverAlreadyQueuedTick()
        XCTAssertEqual(fixture.coordinator.session.phase, .review)
        XCTAssertFalse(fixture.coordinator.busy)
        fixture.coordinator.discard()
        tick.deliverAlreadyQueuedTick()
        XCTAssertEqual(fixture.coordinator.session.phase, .idle)
        XCTAssertEqual(fixture.coordinator.microphone.state, .closed)
        XCTAssertFalse(fixture.coordinator.busy)
        XCTAssertEqual(fixture.resources.counts.value.opened, opened)
        XCTAssertEqual(fixture.inference.counts.value.decodes, decoded)
    }
}
