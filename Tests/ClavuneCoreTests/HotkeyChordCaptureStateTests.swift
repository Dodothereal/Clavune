import Carbon
import XCTest
@testable import ClavuneApp
@testable import ClavuneCore

/// Pure key-edge state and synthetic coordinator boundary only. No NSView,
/// Carbon registration, real keyboard, settings, model, or microphone access.
final class HotkeyChordCaptureStateTests: XCTestCase {
    private let space = UInt32(kVK_Space)
    private let f9 = UInt32(kVK_F9)
    private let commandShift = UInt32(cmdKey | shiftKey)
    private let shift = UInt32(shiftKey)

    func testSecondDistinctKeyPoisonsAttemptRegardlessOfReleaseOrder() {
        for releaseFirst in [true, false] {
            var capture = HotkeyChordCaptureState()
            capture.keyDown(keyCode: space, modifiers: commandShift, repeatEvent: false)
            capture.keyDown(keyCode: f9, modifiers: commandShift, repeatEvent: false)
            let firstUp = releaseFirst ? space : f9
            let secondUp = releaseFirst ? f9 : space
            XCTAssertNil(capture.keyUp(keyCode: firstUp, modifiers: commandShift))
            XCTAssertTrue(capture.hasPending, "The other physical key remains held")
            XCTAssertNil(capture.keyUp(keyCode: secondUp, modifiers: commandShift))
            XCTAssertFalse(capture.hasPending)
            capture.keyDown(keyCode: space, modifiers: commandShift, repeatEvent: false)
            XCTAssertEqual(capture.keyUp(keyCode: space, modifiers: commandShift)?.keyCode,
                           space, "A fresh isolated press may commit")
        }
    }

    func testRepeatDuplicateDownAndUnrelatedUpNeverCreateOrClearPendingPress() {
        var capture = HotkeyChordCaptureState()
        capture.keyDown(keyCode: space, modifiers: commandShift, repeatEvent: true)
        XCTAssertFalse(capture.hasPending, "A repeat cannot begin a new attempt")
        capture.keyDown(keyCode: space, modifiers: commandShift, repeatEvent: false)
        capture.keyDown(keyCode: space, modifiers: commandShift, repeatEvent: false)
        capture.keyDown(keyCode: space, modifiers: commandShift, repeatEvent: true)
        XCTAssertTrue(capture.hasPending)
        XCTAssertNil(capture.keyUp(keyCode: f9, modifiers: commandShift))
        XCTAssertTrue(capture.hasPending)
        XCTAssertEqual(capture.keyUp(keyCode: space, modifiers: commandShift)?.keyCode, space)
        XCTAssertFalse(capture.hasPending)
        XCTAssertNil(capture.keyUp(keyCode: space, modifiers: commandShift),
                     "Duplicate release cannot commit twice")
        capture.keyDown(keyCode: space, modifiers: commandShift, repeatEvent: true)
        XCTAssertFalse(capture.hasPending)
    }

    func testModifierReleaseAndRepressPoisonAttemptEvenIfFinalFlagsMatch() {
        var capture = HotkeyChordCaptureState()
        capture.keyDown(keyCode: space, modifiers: commandShift, repeatEvent: false)
        capture.modifiersChanged(shift) // Command released while Space remains down.
        XCTAssertTrue(capture.hasPending, "The physical Space key is still held")
        capture.modifiersChanged(commandShift) // Command repressed before Space up.
        XCTAssertNil(capture.keyUp(keyCode: space, modifiers: commandShift),
                     "Matching endpoint flags must not rehabilitate a broken chord")
        XCTAssertFalse(capture.hasPending)
    }

    func testKeyUpModifierMismatchRejectsWithoutFlagsChangedDelivery() {
        var capture = HotkeyChordCaptureState()
        capture.keyDown(keyCode: space, modifiers: commandShift, repeatEvent: false)
        XCTAssertNil(capture.keyUp(keyCode: space, modifiers: shift),
                     "Key-up flags independently reject a modifier released before up")
        XCTAssertFalse(capture.hasPending)
    }

    func testUnchangedModifierNotificationsPreserveOneCommit() {
        var capture = HotkeyChordCaptureState()
        capture.keyDown(keyCode: space, modifiers: commandShift, repeatEvent: false)
        capture.modifiersChanged(commandShift)
        capture.modifiersChanged(commandShift)
        let committed = capture.keyUp(keyCode: space, modifiers: commandShift)
        XCTAssertEqual(committed?.keyCode, space)
        XCTAssertEqual(committed?.modifiers, commandShift)
        XCTAssertFalse(capture.hasPending)
    }

    func testFocusLossClearsPendingWithoutCommittingLateRelease() {
        var capture = HotkeyChordCaptureState()
        capture.keyDown(keyCode: space, modifiers: commandShift, repeatEvent: false)
        let hadPendingBeforeFocusLoss = capture.hasPending
        capture.clear()
        XCTAssertTrue(hadPendingBeforeFocusLoss, "Caller must snapshot before clear")
        XCTAssertFalse(capture.hasPending)
        XCTAssertNil(capture.keyUp(keyCode: space, modifiers: commandShift))
        capture.keyDown(keyCode: f9, modifiers: commandShift, repeatEvent: false)
        XCTAssertEqual(capture.keyUp(keyCode: f9, modifiers: commandShift)?.keyCode, f9)
    }

    @MainActor func testFocusLossWithOldChordKeyStillHeldNeverRestoresOldRegistration() throws {
        let fixture = try CoordinatorFixture(modelSelectionEnabled: false)
        let coordinator = fixture.coordinator!
        coordinator.setHotkeyEnabled(true)
        let original = try XCTUnwrap(fixture.hotkeyRegistrar.registrations.first)
        XCTAssertTrue(coordinator.beginHotkeyRecording())
        XCTAssertEqual(original.unregisterCalls, 1)
        var capture = HotkeyChordCaptureState()
        capture.keyDown(keyCode: space, modifiers: commandShift, repeatEvent: false)
        capture.keyDown(keyCode: f9, modifiers: commandShift, repeatEvent: false)
        XCTAssertNil(capture.keyUp(keyCode: f9, modifiers: commandShift))
        XCTAssertTrue(capture.hasPending, "Space, the prior chord's key, is still down")

        // Mirror the focused view's fail-closed focus-loss choice using only
        // pure state and the injected coordinator (never a real NSView).
        let hadPendingBeforeFocusLoss = capture.hasPending
        capture.clear()
        if hadPendingBeforeFocusLoss { coordinator.interruptForPrivacy() }
        else { coordinator.cancelHotkeyRecording() }
        XCTAssertFalse(coordinator.hotkeyRecording)
        XCTAssertFalse(coordinator.hotkeyEnabled)
        XCTAssertEqual(coordinator.developmentShortcut, .controlShiftSpace)
        XCTAssertEqual(fixture.hotkeyRegistrar.shortcuts, [.controlShiftSpace],
                       "The old chord must not re-register under a held Space")
        XCTAssertEqual(fixture.hotkeyRegistrar.activeCount, 0)
        XCTAssertEqual(fixture.resources.counts.value.opened, 0)
        XCTAssertEqual(fixture.permissionCalls, 0)
        coordinator.cancelHotkeyRecording() // A late Cancel must not restore it.
        XCTAssertEqual(fixture.hotkeyRegistrar.shortcuts, [.controlShiftSpace])
    }
}
