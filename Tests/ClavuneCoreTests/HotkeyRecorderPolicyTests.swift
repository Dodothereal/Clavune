import AppKit
import Carbon
import Combine
import XCTest
@testable import ClavuneApp
@testable import ClavuneCore

/// Synthetic coordinator/chord policy only. No Carbon registration, global
/// event monitoring, UI window, permission change, microphone or model access.
final class HotkeyRecorderPolicyTests: UIFixtureAssertions {
    func testFocusedRecorderStagesChordUntilMatchingKeyUpOnly() {
        var capture = HotkeyChordCaptureState()
        let space = UInt32(kVK_Space), other = UInt32(kVK_F9)
        let modifiers = UInt32(cmdKey | shiftKey)
        capture.keyDown(keyCode: space, modifiers: modifiers, repeatEvent: false)
        XCTAssertTrue(capture.hasPending)
        capture.keyDown(keyCode: space, modifiers: modifiers, repeatEvent: true)
        XCTAssertNil(capture.keyUp(keyCode: other, modifiers: modifiers))
        let committed = capture.keyUp(keyCode: space, modifiers: modifiers)
        XCTAssertFalse(capture.hasPending)
        XCTAssertEqual(committed?.keyCode, space)
        XCTAssertEqual(committed?.modifiers, modifiers)
        XCTAssertNil(capture.keyUp(keyCode: space, modifiers: modifiers), "One physical press commits once")
        capture.keyDown(keyCode: space, modifiers: modifiers, repeatEvent: false)
        capture.clear() // focus lost or explicit Cancel
        XCTAssertFalse(capture.hasPending)
        XCTAssertNil(capture.keyUp(keyCode: space, modifiers: modifiers))
        capture.keyDown(keyCode: space, modifiers: modifiers, repeatEvent: false)
        capture.keyDown(keyCode: other, modifiers: modifiers, repeatEvent: false)
        XCTAssertNil(capture.keyUp(keyCode: space, modifiers: modifiers))
        XCTAssertTrue(capture.hasPending, "A second held key must keep Cancel fail-closed")
        XCTAssertNil(capture.keyUp(keyCode: other, modifiers: modifiers))
        XCTAssertFalse(capture.hasPending)
        capture.keyDown(keyCode: space, modifiers: modifiers, repeatEvent: false)
        capture.keyDown(keyCode: other, modifiers: modifiers, repeatEvent: false)
        XCTAssertNil(capture.keyUp(keyCode: other, modifiers: modifiers))
        XCTAssertTrue(capture.hasPending, "F9 is still physically held after F10 up")
        capture.clear() // focus exit must inspect hasPending before this clear and disable
    }

    func testBoundedChordsAndStoredValueRejectReservedOrMalformedChoices() throws {
        let controlShift = UInt32(controlKey | shiftKey)
        let commandShift = UInt32(cmdKey | shiftKey)
        let allowed = try XCTUnwrap(DevelopmentShortcut(keyCode: UInt32(kVK_F9), modifiers: commandShift))
        XCTAssertEqual(DevelopmentShortcut(storageValue: allowed.storageValue), allowed)
        XCTAssertNotNil(DevelopmentShortcut(keyCode: UInt32(kVK_Space), modifiers: controlShift))
        XCTAssertNil(DevelopmentShortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey)))
        XCTAssertNil(DevelopmentShortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey | shiftKey)))
        XCTAssertNil(DevelopmentShortcut(keyCode: UInt32(kVK_F9), modifiers: UInt32(shiftKey)))
        XCTAssertNil(DevelopmentShortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: commandShift))
        XCTAssertNil(DevelopmentShortcut(keyCode: UInt32(kVK_Escape), modifiers: commandShift))
        for malformed in ["", "v0:49:\(controlShift)", "v1:49", "v1:-1:\(controlShift)",
                          "v1:49:\(UInt32(controlKey | optionKey))", "v1:0:\(commandShift)"] {
            XCTAssertNil(DevelopmentShortcut(storageValue: malformed))
        }
    }

    @MainActor func testRecordingWhileOffPersistsOnlyValidatedChoiceNotEnabledState() throws {
        let name = "Clavune.HotkeyFixture." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let fixture = try CoordinatorFixture(preferences: defaults, modelSelectionEnabled: false)
        let coordinator = fixture.coordinator!
        let original = coordinator.developmentShortcut
        XCTAssertTrue(coordinator.beginHotkeyRecording())
        XCTAssertFalse(coordinator.acceptRecordedHotkey(keyCode: UInt32(kVK_ANSI_A),
                                                        modifiers: UInt32(cmdKey | shiftKey)))
        XCTAssertTrue(coordinator.hotkeyRecording)
        XCTAssertEqual(coordinator.developmentShortcut, original)
        XCTAssertNil(defaults.persistentDomain(forName: name)?["recordingShortcutV1"])
        let selected = try XCTUnwrap(DevelopmentShortcut(keyCode: UInt32(kVK_F9),
                                                        modifiers: UInt32(cmdKey | shiftKey)))
        XCTAssertTrue(coordinator.acceptRecordedHotkey(keyCode: selected.keyCode,
                                                       modifiers: selected.modifiers))
        XCTAssertFalse(coordinator.hotkeyEnabled)
        XCTAssertEqual(defaults.string(forKey: "recordingShortcutV1"), selected.storageValue)
        XCTAssertTrue(fixture.hotkeyRegistrar.shortcuts.isEmpty)
        let reopened = try CoordinatorFixture(preferences: defaults, modelSelectionEnabled: false)
        XCTAssertEqual(reopened.coordinator.developmentShortcut, selected)
        XCTAssertFalse(reopened.coordinator.hotkeyEnabled)
        XCTAssertTrue(reopened.hotkeyRegistrar.shortcuts.isEmpty)
    }

    @MainActor func testInvalidStoredChordFallsBackWithoutRewritingPreference() throws {
        let name = "Clavune.HotkeyFixture." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("v1:0:0", forKey: "recordingShortcutV1")
        let fixture = try CoordinatorFixture(preferences: defaults, modelSelectionEnabled: false)
        XCTAssertEqual(fixture.coordinator.developmentShortcut, .controlShiftSpace)
        XCTAssertEqual(defaults.string(forKey: "recordingShortcutV1"), "v1:0:0")
        XCTAssertFalse(fixture.coordinator.hotkeyEnabled)
    }

    @MainActor func testPrivacyNotificationAbortsIdleRecorderWithoutCaptureOrRegistrationRestore() async throws {
        let center = NotificationCenter()
        let fixture = try CoordinatorFixture(modelSelectionEnabled: false, workspaceNotifications: center)
        let coordinator = fixture.coordinator!
        coordinator.setHotkeyEnabled(true)
        XCTAssertTrue(coordinator.beginHotkeyRecording())
        var subscription: AnyCancellable?
        let ended = expectation(description: "synthetic privacy notification ended recorder")
        subscription = coordinator.$hotkeyRecording.filter { !$0 }.prefix(1).sink { _ in ended.fulfill() }
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        await fulfillment(of: [ended], timeout: 2)
        withExtendedLifetime(subscription) {}
        XCTAssertFalse(coordinator.hotkeyRecording)
        XCTAssertFalse(coordinator.hotkeyEnabled)
        XCTAssertEqual(coordinator.developmentShortcut, .controlShiftSpace)
        XCTAssertEqual(fixture.hotkeyRegistrar.activeCount, 0)
        XCTAssertFalse(coordinator.closePending)
        XCTAssertEqual(fixture.resources.counts.value.opened, 0)
        XCTAssertEqual(fixture.permissionCalls, 0)
        XCTAssertEqual(fixture.cancellationAllocationCalls, 0)
    }

    @MainActor func testSecureInputAtAcceptFailsClosedWithoutChangingChoice() throws {
        let fixture = try CoordinatorFixture(modelSelectionEnabled: false)
        let coordinator = fixture.coordinator!
        XCTAssertTrue(coordinator.beginHotkeyRecording())
        fixture.privacy.value = false // synthetic Secure Input, no OS state change
        XCTAssertFalse(coordinator.acceptRecordedHotkey(keyCode: UInt32(kVK_F9),
                                                        modifiers: UInt32(cmdKey | shiftKey)))
        XCTAssertFalse(coordinator.hotkeyRecording)
        XCTAssertFalse(coordinator.hotkeyEnabled)
        XCTAssertEqual(coordinator.developmentShortcut, .controlShiftSpace)
        XCTAssertTrue(fixture.hotkeyRegistrar.shortcuts.isEmpty)
        XCTAssertFalse(coordinator.closePending)
        XCTAssertEqual(fixture.resources.counts.value.opened, 0)
        XCTAssertEqual(fixture.permissionCalls, 0)
    }

    @MainActor func testSynchronousFailedRegistrarCannotAdmitCaptureBeforeReturn() throws {
        let attempts = FixtureValue(0)
        let fixture = try CoordinatorFixture(configureEnvironment: { environment in
            environment.registerHotkey = { _, action in
                attempts.value += 1
                action(true) // adversarial synchronous callback before registration result
                throw FixtureHotkeyRegistrar.RegistrationError.conflict
            }
        })
        fixture.coordinator.setHotkeyEnabled(true)
        XCTAssertEqual(attempts.value, 1)
        XCTAssertFalse(fixture.coordinator.hotkeyEnabled)
        XCTAssertEqual(fixture.coordinator.session.phase, .idle)
        XCTAssertNil(fixture.coordinator.session.id)
        XCTAssertEqual(fixture.resources.counts.value.opened, 0)
        XCTAssertEqual(fixture.permissionCalls, 0)
        XCTAssertEqual(fixture.cancellationAllocationCalls, 0)
    }

    @MainActor func testGenericCancelFromAnotherHostCannotRearmWhileChordKeyIsHeld() throws {
        let fixture = try CoordinatorFixture(modelSelectionEnabled: false)
        let coordinator = fixture.coordinator!
        coordinator.setHotkeyEnabled(true)
        XCTAssertTrue(coordinator.beginHotkeyRecording())
        coordinator.setHotkeyChordPending(true) // synthetic focused keyDown, no keyUp
        coordinator.cancel() // same shared action used by either mounted host
        XCTAssertFalse(coordinator.hotkeyRecording)
        XCTAssertFalse(coordinator.hotkeyChordPending)
        XCTAssertFalse(coordinator.hotkeyEnabled)
        XCTAssertEqual(fixture.hotkeyRegistrar.shortcuts, [.controlShiftSpace],
                       "Prior chord must not register again under a held trigger key")
        XCTAssertEqual(fixture.hotkeyRegistrar.activeCount, 0)
        XCTAssertFalse(coordinator.closePending)
        XCTAssertEqual(fixture.resources.counts.value.opened, 0)
        XCTAssertEqual(fixture.permissionCalls, 0)
    }

    @MainActor func testQuitCancelPreservesDirtyReviewButDoesNotRearmHeldShortcut() async throws {
        let fixture = try CoordinatorFixture(configureEnvironment: { environment in
            environment.confirmUnsavedReviewQuit = { _ in .cancel }
        })
        await startRecording(fixture); await stopToReview(fixture)
        let coordinator = fixture.coordinator!
        coordinator.editedText = "Unsaved synthetic review"
        let reviewID = coordinator.session.id
        coordinator.setHotkeyEnabled(true)
        XCTAssertTrue(coordinator.beginHotkeyRecording())
        coordinator.setHotkeyChordPending(true)
        coordinator.quit()
        XCTAssertFalse(coordinator.hotkeyRecording)
        XCTAssertFalse(coordinator.hotkeyEnabled)
        XCTAssertEqual(fixture.hotkeyRegistrar.shortcuts, [.controlShiftSpace])
        XCTAssertEqual(fixture.hotkeyRegistrar.activeCount, 0)
        XCTAssertEqual(coordinator.session.phase, .review)
        XCTAssertEqual(coordinator.session.id, reviewID)
        XCTAssertEqual(coordinator.editedText, "Unsaved synthetic review")
        XCTAssertEqual(fixture.terminationCalls, 0)
    }

    @MainActor func testLostHoldReleasePrivacyDisablesRegistrationAndAllowsExplicitRetry() throws {
        let fixture = try CoordinatorFixture(modelSelectionEnabled: false)
        let coordinator = fixture.coordinator!
        coordinator.setHotkeyEnabled(true)
        let retired = try XCTUnwrap(fixture.hotkeyRegistrar.registrations.first)
        retired.send(down: true) // no model, so no capture; physical release is deliberately lost
        XCTAssertFalse(coordinator.beginHotkeyRecording())
        coordinator.interruptForPrivacy()
        XCTAssertFalse(coordinator.hotkeyEnabled)
        XCTAssertEqual(retired.unregisterCalls, 1)
        retired.deliverAlreadyQueued(down: false)
        XCTAssertFalse(coordinator.hotkeyEnabled)
        XCTAssertEqual(fixture.resources.counts.value.opened, 0)
        XCTAssertEqual(fixture.permissionCalls, 0)
        coordinator.setHotkeyEnabled(true)
        XCTAssertTrue(coordinator.hotkeyEnabled)
        XCTAssertEqual(fixture.hotkeyRegistrar.activeCount, 1)
        XCTAssertTrue(coordinator.beginHotkeyRecording(), "Lost release cannot strand a pressed latch")
        coordinator.cancelHotkeyRecording()
        coordinator.setHotkeyEnabled(false)
    }

    @MainActor func testLostReleaseDuringAdmittedCaptureRetiresHotkeyAndDrainsBeforeExplicitRetry() async throws {
        let fixture = try CoordinatorFixture()
        let coordinator = fixture.coordinator!
        coordinator.setHotkeyEnabled(true)
        let retired = try XCTUnwrap(fixture.hotkeyRegistrar.registrations.first)
        let firstRecording = expectation(description: "first synthetic hotkey down records")
        fixture.observePhase(.recording, expectation: firstRecording)
        retired.send(down: true)
        await fulfillment(of: [firstRecording], timeout: 2)
        await waitForOperation(fixture)
        let closed = expectation(description: "privacy close acknowledged")
        coordinator.interruptForPrivacy() // synthetic sleep/resign before physical key-up
        XCTAssertFalse(coordinator.hotkeyEnabled)
        XCTAssertEqual(retired.unregisterCalls, 1)
        XCTAssertEqual(coordinator.session.phase, .cancelled)
        XCTAssertTrue(coordinator.closePending)
        fixture.observeCloseFinished(closed)
        await fulfillment(of: [closed], timeout: 2)
        await waitForOperation(fixture)
        XCTAssertEqual(fixture.resources.counts.value.opened, 1)
        XCTAssertEqual(fixture.resources.counts.value.closed, 1)
        retired.deliverAlreadyQueued(down: false)
        XCTAssertEqual(coordinator.session.phase, .cancelled)
        XCTAssertEqual(fixture.inference.counts.value.decodes, 0)
        coordinator.setHotkeyEnabled(true) // explicit user choice after privacy recovery
        let fresh = try XCTUnwrap(fixture.hotkeyRegistrar.registrations.last)
        XCTAssertFalse(fresh === retired)
        let secondRecording = expectation(description: "new registration starts once")
        fixture.observePhase(.recording, expectation: secondRecording)
        fresh.send(down: true)
        fresh.send(down: true) // duplicate press must not start a second session
        await fulfillment(of: [secondRecording], timeout: 2)
        await waitForOperation(fixture)
        XCTAssertEqual(fixture.resources.counts.value.opened, 2)
        let reviewed = expectation(description: "new registration release ends hold")
        fixture.observePhase(.review, expectation: reviewed)
        fresh.send(down: false)
        await fulfillment(of: [reviewed], timeout: 2)
        await waitForOperation(fixture)
        XCTAssertEqual(fixture.inference.counts.value.decodes, 1)
        coordinator.setHotkeyEnabled(false)
    }

    @MainActor func testDuplicateAndLateHoldEdgesOwnOnlyTheirAdmittedSession() async throws {
        let fixture = try CoordinatorFixture()
        let coordinator = fixture.coordinator!
        coordinator.setHotkeyEnabled(true)
        let registration = try XCTUnwrap(fixture.hotkeyRegistrar.registrations.first)
        let recording = expectation(description: "first hotkey down admitted once")
        fixture.observePhase(.recording, expectation: recording)
        registration.send(down: true)
        registration.send(down: true)
        await fulfillment(of: [recording], timeout: 2)
        await waitForOperation(fixture)
        XCTAssertEqual(fixture.resources.counts.value.opened, 1)
        let review = expectation(description: "first matching up stops once")
        fixture.observePhase(.review, expectation: review)
        registration.send(down: false)
        registration.send(down: false)
        await fulfillment(of: [review], timeout: 2)
        await waitForOperation(fixture)
        XCTAssertEqual(fixture.inference.counts.value.decodes, 1)
        let reviewID = coordinator.session.id
        registration.send(down: true) // review denies new admission
        registration.send(down: false)
        XCTAssertEqual(coordinator.session.id, reviewID)
        XCTAssertEqual(coordinator.session.phase, .review)
        coordinator.discard()
        let manual = expectation(description: "separate manual session records")
        fixture.observePhase(.recording, expectation: manual)
        coordinator.start()
        await fulfillment(of: [manual], timeout: 2)
        await waitForOperation(fixture)
        registration.send(down: false) // late release from prior denied press
        XCTAssertEqual(coordinator.session.phase, .recording)
        XCTAssertEqual(fixture.resources.counts.value.opened, 2)
        await stopToReview(fixture)
        XCTAssertEqual(fixture.inference.counts.value.decodes, 2)
        coordinator.setHotkeyEnabled(false)
    }
}
