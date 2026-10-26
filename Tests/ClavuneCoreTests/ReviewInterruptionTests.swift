import AppKit
import Combine
import XCTest
@testable import ClavuneApp
@testable import ClavuneCore

/// Production coordinator actions with synthetic notifications/hotkeys/resources.
/// No real sleep, Secure Input setting, microphone, clipboard, or model is touched.
final class ReviewInterruptionTests: UIFixtureAssertions {
    private struct ReviewSnapshot {
        let id: UUID?
        let raw: String
        let edited: String
        let metricsSession: UUID?
    }

    @MainActor private func snapshot(_ fixture: CoordinatorFixture) -> ReviewSnapshot {
        ReviewSnapshot(id: fixture.coordinator.session.id,
            raw: fixture.coordinator.session.rawTranscript,
            edited: fixture.coordinator.editedText,
            metricsSession: fixture.coordinator.metrics?.session)
    }

    @MainActor private func assertReview(_ fixture: CoordinatorFixture, _ before: ReviewSnapshot,
                                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(fixture.coordinator.session.phase, .review, file: file, line: line)
        XCTAssertEqual(fixture.coordinator.session.id, before.id, file: file, line: line)
        XCTAssertEqual(fixture.coordinator.session.rawTranscript, before.raw, file: file, line: line)
        XCTAssertEqual(fixture.coordinator.editedText, before.edited, file: file, line: line)
        XCTAssertEqual(fixture.coordinator.metrics?.session, before.metricsSession, file: file, line: line)
        XCTAssertFalse(fixture.coordinator.canStart, file: file, line: line)
        XCTAssertTrue(fixture.clipboard.calls.isEmpty, file: file, line: line)
    }

    @MainActor func testIdleReviewSurvivesRepeatedPrivacyInterruptionsEvenWhenEmpty() async throws {
        for transcript in ["Synthetic raw result", ""] {
            let fixture = try CoordinatorFixture()
            fixture.inference.transcript = transcript
            await startRecording(fixture); await stopToReview(fixture)
            fixture.coordinator.editedText = ""
            let before = snapshot(fixture)
            let message = fixture.coordinator.message
            fixture.coordinator.interruptForPrivacy()
            fixture.coordinator.interruptForPrivacy()
            assertReview(fixture, before)
            XCTAssertFalse(fixture.coordinator.busy)
            XCTAssertFalse(fixture.coordinator.closePending)
            XCTAssertEqual(fixture.coordinator.message, message)
            XCTAssertEqual(fixture.resources.counts.value.opened, 1)
            XCTAssertEqual(fixture.resources.counts.value.closed, 1)
            fixture.coordinator.discard()
            XCTAssertTrue(fixture.coordinator.canStart)
            XCTAssertTrue(fixture.coordinator.editedText.isEmpty)
            XCTAssertTrue(fixture.coordinator.session.rawTranscript.isEmpty)
        }
    }

    @MainActor func testSecureInputHotkeyPreservesEditedReviewInHoldAndToggleModes() async throws {
        let fixture = try CoordinatorFixture()
        fixture.coordinator.setHotkeyEnabled(true)
        let registration = try XCTUnwrap(fixture.hotkeyRegistrar.registrations.first)
        await startRecording(fixture); await stopToReview(fixture)
        fixture.coordinator.editedText = "Keep this synthetic draft — Grüße"
        let before = snapshot(fixture)
        fixture.privacy.value = false
        for hold in [true, false] {
            fixture.coordinator.holdToTalk = hold
            for _ in 0..<2 {
                registration.send(down: true); registration.send(down: false)
                assertReview(fixture, before)
                XCTAssertFalse(fixture.coordinator.busy)
            }
        }
        XCTAssertEqual(fixture.cancellationAllocationCalls, 1)
        XCTAssertEqual(fixture.inference.counts.value.loads, 1)
        XCTAssertEqual(fixture.resources.counts.value.opened, 1)
        fixture.coordinator.setHotkeyEnabled(false)
    }

    @MainActor func testWorkspaceNotificationsPreserveReviewWhileCancellingModelWork() async throws {
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            let center = NotificationCenter()
            let fixture = try CoordinatorFixture(workspaceNotifications: center)
            await startRecording(fixture); await stopToReview(fixture)
            fixture.coordinator.editedText = "Review remains while model work drains"
            let before = snapshot(fixture)
            let unload = ControlledDelivery()
            let entered = expectation(description: "synthetic model unload suspended")
            let unloadWasCancelled = FixtureValue(false)
            fixture.inference.unloadGate = unload; fixture.inference.onUnload = entered
            fixture.inference.onUnloadCompleted = { unloadWasCancelled.value = Task.isCancelled }
            fixture.coordinator.unload()
            await fulfillment(of: [entered], timeout: 2)
            await unload.waitUntilSuspended()

            let cancelled = expectation(description: "actual notification route cancelled model work")
            let observation = fixture.coordinator.$message.dropFirst()
                .filter { $0 == "Modellvorgang abgebrochen. Die Vorschau bleibt erhalten." }.prefix(1)
                .sink { _ in cancelled.fulfill() }
            center.post(name: name, object: nil)
            await fulfillment(of: [cancelled], timeout: 2)
            observation.cancel()
            assertReview(fixture, before)
            XCTAssertTrue(fixture.coordinator.operationPending,
                          "Privacy interruption must not pretend the held model work has drained")
            XCTAssertEqual(fixture.coordinator.microphone.state, .closed)

            await unload.release()
            await waitForOperation(fixture)
            assertReview(fixture, before)
            XCTAssertFalse(fixture.coordinator.busy)
            XCTAssertTrue(unloadWasCancelled.value, "The review is preserved, not the model task")
            XCTAssertEqual(fixture.resources.counts.value.opened, 1)
        }
    }

    @MainActor func testPrivacyInterruptionStillClosesActiveRecording() async throws {
        let fixture = try CoordinatorFixture()
        await startRecording(fixture)
        fixture.coordinator.interruptForPrivacy()
        XCTAssertEqual(fixture.coordinator.session.phase, .cancelled)
        let closed = expectation(description: "active capture close acknowledged")
        fixture.observeCloseFinished(closed)
        await fulfillment(of: [closed], timeout: 2)
        await waitForOperation(fixture)
        XCTAssertEqual(fixture.coordinator.microphone.state, .closed)
        XCTAssertFalse(fixture.coordinator.busy)
        XCTAssertEqual(fixture.resources.counts.value.closed, 1)
        XCTAssertEqual(fixture.watchdog.activeCount, 0)
        XCTAssertTrue(fixture.clipboard.calls.isEmpty)
    }

    @MainActor func testPrivacyInterruptionRejectsLateTranscription() async throws {
        let fixture = try CoordinatorFixture()
        await startRecording(fixture)
        let decode = ControlledDelivery()
        let entered = expectation(description: "synthetic decode suspended")
        fixture.inference.decodeGate = decode; fixture.inference.onDecode = entered
        fixture.coordinator.stop()
        await fulfillment(of: [entered], timeout: 2)
        await decode.waitUntilSuspended()
        XCTAssertEqual(fixture.coordinator.session.phase, .transcribing)
        fixture.coordinator.interruptForPrivacy()
        XCTAssertEqual(fixture.coordinator.session.phase, .cancelled)
        let closed = expectation(description: "decode interruption close acknowledged")
        fixture.observeCloseFinished(closed)
        await decode.release()
        await fulfillment(of: [closed], timeout: 2)
        await waitForOperation(fixture)
        XCTAssertEqual(fixture.coordinator.session.phase, .cancelled)
        XCTAssertTrue(fixture.coordinator.session.rawTranscript.isEmpty)
        XCTAssertTrue(fixture.coordinator.editedText.isEmpty)
        XCTAssertFalse(fixture.coordinator.busy)
        XCTAssertTrue(fixture.clipboard.calls.isEmpty)
    }

    @MainActor func testCancelAndQuitCancelPreserveReviewDuringModelDrain() async throws {
        for quit in [false, true] {
            var confirmations = 0
            let fixture = try CoordinatorFixture(configureEnvironment: { environment in
                environment.confirmUnsavedReviewQuit = { _ in confirmations += 1; return .cancel }
            })
            await startRecording(fixture); await stopToReview(fixture)
            fixture.coordinator.editedText = "Keep the review while unrelated model work drains"
            let before = snapshot(fixture)
            let unload = ControlledDelivery()
            let entered = expectation(description: "model work held before interruption")
            fixture.inference.unloadGate = unload; fixture.inference.onUnload = entered
            fixture.coordinator.unload()
            await fulfillment(of: [entered], timeout: 2)
            await unload.waitUntilSuspended()
            fixture.coordinator.interruptForPrivacy()
            XCTAssertFalse(fixture.coordinator.closePending,
                           "Model work never reopened the microphone and needs no capture close")
            assertReview(fixture, before)
            if quit { fixture.coordinator.quit(); fixture.coordinator.quit() }
            else { fixture.coordinator.cancel() }
            assertReview(fixture, before)
            XCTAssertEqual(confirmations, quit ? 2 : 0,
                           "Each completed Cancel decision permits a later deliberate Quit")
            XCTAssertEqual(fixture.terminationCalls, 0)
            XCTAssertTrue(fixture.coordinator.operationPending)
            await unload.release()
            await waitForOperation(fixture)
            assertReview(fixture, before)
            XCTAssertEqual(fixture.coordinator.microphone.state, .closed)
            XCTAssertFalse(fixture.coordinator.busy)
            XCTAssertEqual(fixture.terminationCalls, 0)
        }
    }
}
