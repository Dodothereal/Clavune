import XCTest
@testable import ClavuneApp
@testable import ClavuneCore

/// Proposed configurable-recorder contract. The registrar is fully synthetic:
/// no Carbon registration, UI host, settings write, or microphone/model access.
/// These tests require the product owner's recorder implementation before build.
final class HotkeyRecorderTransactionTests: UIFixtureAssertions {
    @MainActor func testCollisionRestoresPreviouslyEnabledShortcut() throws {
        let fixture = try CoordinatorFixture(modelSelectionEnabled: false)
        let coordinator = fixture.coordinator!
        let old = DevelopmentShortcut.controlShiftSpace
        let candidate = DevelopmentShortcut.commandShiftSpace
        coordinator.setHotkeyEnabled(true)
        let original = try XCTUnwrap(fixture.hotkeyRegistrar.registrations.first)
        XCTAssertTrue(coordinator.beginHotkeyRecording())
        XCTAssertTrue(coordinator.hotkeyRecording)
        XCTAssertEqual(original.unregisterCalls, 1)
        fixture.hotkeyRegistrar.blockedShortcuts = [candidate]

        XCTAssertFalse(coordinator.acceptRecordedHotkey(keyCode: candidate.keyCode,
                                                        modifiers: candidate.modifiers))
        XCTAssertFalse(coordinator.hotkeyRecording)
        XCTAssertEqual(coordinator.developmentShortcut, old)
        XCTAssertTrue(coordinator.hotkeyEnabled)
        XCTAssertEqual(fixture.hotkeyRegistrar.shortcuts, [old, candidate, old])
        XCTAssertEqual(fixture.hotkeyRegistrar.activeCount, 1)
        XCTAssertEqual(fixture.hotkeyRegistrar.registrations.count, 2)
        XCTAssertTrue(fixture.hotkeyRegistrar.registrations[1].active)
        XCTAssertEqual(fixture.resources.counts.value.opened, 0)
        XCTAssertEqual(fixture.permissionCalls, 0)
        coordinator.setHotkeyEnabled(false)
        XCTAssertEqual(fixture.hotkeyRegistrar.activeCount, 0)
        XCTAssertEqual(fixture.hotkeyRegistrar.registrations[1].unregisterCalls, 1)
    }

    @MainActor func testOneShotRegistrationFailureRestoresPreviousChoiceAndCanRetry() throws {
        let fixture = try CoordinatorFixture(modelSelectionEnabled: false)
        let coordinator = fixture.coordinator!
        let old = DevelopmentShortcut.controlShiftSpace
        let candidate = DevelopmentShortcut.commandShiftSpace
        coordinator.setHotkeyEnabled(true)
        XCTAssertTrue(coordinator.beginHotkeyRecording())
        fixture.hotkeyRegistrar.failuresRemaining = 1 // candidate only; restoration succeeds
        XCTAssertFalse(coordinator.acceptRecordedHotkey(keyCode: candidate.keyCode,
                                                        modifiers: candidate.modifiers))
        XCTAssertEqual(coordinator.developmentShortcut, old)
        XCTAssertEqual(fixture.hotkeyRegistrar.shortcuts, [old, candidate, old])
        XCTAssertEqual(fixture.hotkeyRegistrar.activeCount, 1)

        XCTAssertTrue(coordinator.beginHotkeyRecording())
        XCTAssertTrue(coordinator.acceptRecordedHotkey(keyCode: candidate.keyCode,
                                                       modifiers: candidate.modifiers))
        XCTAssertEqual(coordinator.developmentShortcut, candidate)
        XCTAssertTrue(coordinator.hotkeyEnabled)
        XCTAssertEqual(fixture.hotkeyRegistrar.shortcuts, [old, candidate, old, candidate])
        XCTAssertEqual(fixture.hotkeyRegistrar.activeCount, 1)
        XCTAssertEqual(fixture.hotkeyRegistrar.registrations[1].unregisterCalls, 1)
        coordinator.setHotkeyEnabled(false)
        XCTAssertEqual(fixture.hotkeyRegistrar.activeCount, 0)
    }

    @MainActor func testCancelRestoresOldChordAndLateCallbackCannotPoisonNextRecording() throws {
        let fixture = try CoordinatorFixture(modelSelectionEnabled: false)
        let coordinator = fixture.coordinator!
        let old = DevelopmentShortcut.controlShiftSpace
        coordinator.setHotkeyEnabled(true)
        let retired = try XCTUnwrap(fixture.hotkeyRegistrar.registrations.first)
        XCTAssertTrue(coordinator.beginHotkeyRecording())
        retired.deliverAlreadyQueued(down: true) // synthetic stale delivery after unregister
        XCTAssertTrue(coordinator.hotkeyRecording)
        coordinator.cancelHotkeyRecording()
        XCTAssertFalse(coordinator.hotkeyRecording)
        XCTAssertTrue(coordinator.hotkeyEnabled)
        XCTAssertEqual(coordinator.developmentShortcut, old)
        XCTAssertEqual(fixture.hotkeyRegistrar.shortcuts, [old, old])
        XCTAssertEqual(fixture.hotkeyRegistrar.activeCount, 1)
        XCTAssertEqual(fixture.resources.counts.value.opened, 0)
        XCTAssertEqual(fixture.permissionCalls, 0)
        XCTAssertTrue(coordinator.beginHotkeyRecording(), "Stale down must not leave a held-key latch")
        coordinator.cancelHotkeyRecording()
        coordinator.setHotkeyEnabled(false)
    }

    @MainActor func testHeldPressRejectsRecorderBeginUntilReleaseWithoutOpeningCapture() throws {
        let fixture = try CoordinatorFixture(modelSelectionEnabled: false)
        let coordinator = fixture.coordinator!
        coordinator.setHotkeyEnabled(true)
        let registration = try XCTUnwrap(fixture.hotkeyRegistrar.registrations.first)
        registration.send(down: true) // start() is inadmissible without a selected model
        XCTAssertFalse(coordinator.beginHotkeyRecording())
        XCTAssertFalse(coordinator.hotkeyRecording)
        XCTAssertEqual(registration.unregisterCalls, 0)
        XCTAssertEqual(fixture.hotkeyRegistrar.activeCount, 1)
        XCTAssertEqual(fixture.resources.counts.value.opened, 0)
        XCTAssertEqual(fixture.permissionCalls, 0)
        registration.send(down: false)
        XCTAssertTrue(coordinator.beginHotkeyRecording())
        XCTAssertEqual(registration.unregisterCalls, 1)
        coordinator.cancelHotkeyRecording()
        coordinator.setHotkeyEnabled(false)
    }

    @MainActor func testFailedRestorationDisablesInsteadOfClaimingShortcutActive() throws {
        let fixture = try CoordinatorFixture(modelSelectionEnabled: false)
        let coordinator = fixture.coordinator!
        let old = DevelopmentShortcut.controlShiftSpace
        let candidate = DevelopmentShortcut.commandShiftSpace
        coordinator.setHotkeyEnabled(true)
        let registeredStatus = coordinator.hotkeyStatus
        XCTAssertTrue(coordinator.beginHotkeyRecording())
        fixture.hotkeyRegistrar.blockedShortcuts = [candidate, old]
        XCTAssertFalse(coordinator.acceptRecordedHotkey(keyCode: candidate.keyCode,
                                                        modifiers: candidate.modifiers))
        XCTAssertFalse(coordinator.hotkeyRecording)
        XCTAssertFalse(coordinator.hotkeyEnabled)
        XCTAssertEqual(coordinator.developmentShortcut, old)
        XCTAssertEqual(fixture.hotkeyRegistrar.shortcuts, [old, candidate, old])
        XCTAssertEqual(fixture.hotkeyRegistrar.activeCount, 0)
        XCTAssertFalse(coordinator.hotkeyStatus.isEmpty)
        XCTAssertNotEqual(coordinator.hotkeyStatus, registeredStatus)
    }

    @MainActor func testRecordingWhileDisabledStoresChoiceButDoesNotEnable() throws {
        let fixture = try CoordinatorFixture(modelSelectionEnabled: false)
        let coordinator = fixture.coordinator!
        let candidate = DevelopmentShortcut.commandShiftSpace
        XCTAssertFalse(coordinator.hotkeyEnabled)
        XCTAssertTrue(coordinator.beginHotkeyRecording())
        XCTAssertTrue(coordinator.acceptRecordedHotkey(keyCode: candidate.keyCode,
                                                       modifiers: candidate.modifiers))
        XCTAssertEqual(coordinator.developmentShortcut, candidate)
        XCTAssertFalse(coordinator.hotkeyEnabled)
        XCTAssertTrue(fixture.hotkeyRegistrar.shortcuts.isEmpty)
        XCTAssertEqual(fixture.hotkeyRegistrar.activeCount, 0)
        XCTAssertEqual(fixture.resources.counts.value.opened, 0)
    }

    @MainActor func testPrivacyReentryDuringRegistrationRetiresReturnedHandle() throws {
        let registrar = FixtureHotkeyRegistrar()
        weak var owner: AppCoordinator?
        let fixture = try CoordinatorFixture(modelSelectionEnabled: false, configureEnvironment: { environment in
            environment.registerHotkey = { shortcut, action in
                let candidate = try registrar.register(shortcut, action: action)
                owner?.interruptForPrivacy()
                return candidate
            }
        })
        let coordinator = fixture.coordinator!
        owner = coordinator

        coordinator.setHotkeyEnabled(true)
        XCTAssertFalse(coordinator.hotkeyEnabled)
        XCTAssertEqual(registrar.activeCount, 0)
        XCTAssertEqual(registrar.registrations.first?.unregisterCalls, 1)
        XCTAssertEqual(coordinator.hotkeyStatus,
                       "Datenschutz-Unterbrechung; Hotkey aus. Bei Bedarf bewusst erneut aktivieren.")
        XCTAssertEqual(fixture.permissionCalls, 0)
        XCTAssertEqual(fixture.cancellationAllocationCalls, 0)
        XCTAssertEqual(fixture.resources.counts.value.opened, 0)
    }

    @MainActor func testNestedConfigureRetainsOnlyNewestRegistration() throws {
        let registrar = FixtureHotkeyRegistrar()
        weak var owner: AppCoordinator?
        var didReenter = false
        let fixture = try CoordinatorFixture(modelSelectionEnabled: false, configureEnvironment: { environment in
            environment.registerHotkey = { shortcut, action in
                let candidate = try registrar.register(shortcut, action: action)
                if !didReenter {
                    didReenter = true
                    owner?.configureHotkey()
                }
                return candidate
            }
        })
        let coordinator = fixture.coordinator!
        owner = coordinator

        coordinator.setHotkeyEnabled(true)
        XCTAssertTrue(didReenter)
        XCTAssertTrue(coordinator.hotkeyEnabled)
        XCTAssertEqual(registrar.registrations.count, 2)
        XCTAssertEqual(registrar.activeCount, 1)
        XCTAssertEqual(registrar.registrations.first?.unregisterCalls, 1)
        XCTAssertTrue(registrar.registrations[1].active)

        coordinator.setHotkeyEnabled(false)
        XCTAssertEqual(registrar.activeCount, 0)
        XCTAssertEqual(registrar.registrations[1].unregisterCalls, 1)
    }

    @MainActor func testReentrantHoldReleaseDuringStartupCancelsAdmittedSession() async throws {
        var registered: FixtureHotkeyRegistrar.Registration?
        var released = false
        let fixture = try CoordinatorFixture(configureEnvironment: { environment in
            environment.makeWatchdog = { _ in
                if !released {
                    released = true
                    registered?.send(down: false)
                }
                return {}
            }
        })
        let coordinator = fixture.coordinator!
        coordinator.setHotkeyEnabled(true)
        registered = try XCTUnwrap(fixture.hotkeyRegistrar.registrations.first)

        registered?.send(down: true)
        XCTAssertTrue(released, "The injected startup boundary delivered the matching key-up")
        XCTAssertEqual(coordinator.session.phase, .cancelled)
        await waitForOperation(fixture)
        XCTAssertEqual(fixture.resources.counts.value.opened, 0)
        XCTAssertEqual(fixture.permissionCalls, 0)
        XCTAssertEqual(fixture.inference.counts.value.loads, 0)
        coordinator.setHotkeyEnabled(false)
    }

    @MainActor func testPrivacyUnregisterReentryCannotOrphanARegistration() throws {
        let fixture = try CoordinatorFixture(modelSelectionEnabled: false)
        let coordinator = fixture.coordinator!
        coordinator.setHotkeyEnabled(true)
        let original = try XCTUnwrap(fixture.hotkeyRegistrar.registrations.first)
        original.onUnregister = { coordinator.configureHotkey() }

        coordinator.interruptForPrivacy()
        XCTAssertFalse(coordinator.hotkeyEnabled)
        XCTAssertEqual(fixture.hotkeyRegistrar.activeCount, 0)
        XCTAssertEqual(fixture.hotkeyRegistrar.registrations.count, 1)
        XCTAssertEqual(original.unregisterCalls, 1)
        XCTAssertEqual(coordinator.hotkeyStatus,
                       "Datenschutz-Unterbrechung; Hotkey aus. Bei Bedarf bewusst erneut aktivieren.")
    }

    @MainActor func testPrivacyUnregisterCannotReenableDuringRetirement() throws {
        let fixture = try CoordinatorFixture(modelSelectionEnabled: false)
        let coordinator = fixture.coordinator!
        coordinator.setHotkeyEnabled(true)
        let original = try XCTUnwrap(fixture.hotkeyRegistrar.registrations.first)
        original.onUnregister = { coordinator.setHotkeyEnabled(true) }

        coordinator.interruptForPrivacy()
        XCTAssertFalse(coordinator.hotkeyEnabled)
        XCTAssertEqual(fixture.hotkeyRegistrar.registrations.count, 1)
        XCTAssertEqual(fixture.hotkeyRegistrar.activeCount, 0)
        XCTAssertEqual(original.unregisterCalls, 1)
    }

    @MainActor func testQuitDuringFailedNewRegistrationDoesNotRestoreOldShortcut() async throws {
        let old = DevelopmentShortcut.controlShiftSpace
        let selected = DevelopmentShortcut.commandShiftSpace
        let registrar = FixtureHotkeyRegistrar()
        weak var owner: AppCoordinator?
        var armed = false
        var attempts: [DevelopmentShortcut] = []
        let fixture = try CoordinatorFixture(modelSelectionEnabled: false, configureEnvironment: { environment in
            environment.registerHotkey = { shortcut, action in
                attempts.append(shortcut)
                if armed && shortcut == selected {
                    owner?.quit()
                    throw FixtureHotkeyRegistrar.RegistrationError.conflict
                }
                return try registrar.register(shortcut, action: action)
            }
        })
        let coordinator = fixture.coordinator!
        owner = coordinator
        coordinator.setHotkeyEnabled(true)
        XCTAssertTrue(coordinator.beginHotkeyRecording())
        let terminated = expectation(description: "reentrant Quit drained")
        fixture.terminated = terminated
        armed = true

        XCTAssertFalse(coordinator.acceptRecordedHotkey(keyCode: selected.keyCode,
                                                         modifiers: selected.modifiers))
        XCTAssertEqual(attempts, [old, selected])
        XCTAssertEqual(registrar.activeCount, 0)
        await fulfillment(of: [terminated], timeout: 2)
        XCTAssertEqual(fixture.terminationCalls, 1)
    }
}
