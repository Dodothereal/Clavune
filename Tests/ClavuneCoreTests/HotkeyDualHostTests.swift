import AppKit
import SwiftUI
import XCTest
@testable import ClavuneApp

/// Opt-in, in-memory AppKit hosts only. No window, status item, Carbon registration or pasteboard.
/// This verifies the production binding path; native control clicks/AX/visible layout are separate gates.
final class HotkeyDualHostTests: XCTestCase {
    @MainActor func testTwoMountedHostsMirrorCommandsWithoutDuplicateRegistrationOnRemount() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CLAVUNE_RUN_UI_HOST_FIXTURES"] == "1",
                          "Run only in the authorized macOS in-memory UI-host fixture pass")
        let fixture = try CoordinatorFixture()
        let menu = NSHostingView(rootView: DictationView(coordinator: fixture.coordinator))
        var panel: NSHostingView<DictationView>? = NSHostingView(rootView: DictationView(coordinator: fixture.coordinator))
        menu.frame = NSRect(x: 0, y: 0, width: 440, height: 700)
        panel?.frame = menu.frame
        menu.layoutSubtreeIfNeeded(); panel?.layoutSubtreeIfNeeded()
        menu.rootView.hotkeyEnabledBinding.wrappedValue = true
        XCTAssertTrue(try XCTUnwrap(panel).rootView.hotkeyEnabledBinding.wrappedValue)
        try XCTUnwrap(panel).rootView.hotkeyEnabledBinding.wrappedValue = true
        XCTAssertEqual(fixture.hotkeyRegistrar.shortcuts.count, 1)
        XCTAssertEqual(fixture.hotkeyRegistrar.activeCount, 1)
        menu.isHidden = true; menu.isHidden = false
        panel = nil
        panel = NSHostingView(rootView: DictationView(coordinator: fixture.coordinator))
        panel?.frame = menu.frame
        menu.layoutSubtreeIfNeeded(); panel?.layoutSubtreeIfNeeded()
        let refreshed = expectation(description: "both hosts receive a later main queue turn")
        DispatchQueue.main.async { refreshed.fulfill() }
        await fulfillment(of: [refreshed], timeout: 2)
        XCTAssertTrue(try XCTUnwrap(panel).rootView.hotkeyEnabledBinding.wrappedValue)
        XCTAssertEqual(fixture.hotkeyRegistrar.shortcuts.count, 1)
        XCTAssertEqual(fixture.hotkeyRegistrar.registrations.first?.unregisterCalls, 0)
        try XCTUnwrap(panel).rootView.hotkeyEnabledBinding.wrappedValue = false
        XCTAssertFalse(menu.rootView.hotkeyEnabledBinding.wrappedValue)
        menu.rootView.hotkeyEnabledBinding.wrappedValue = false
        XCTAssertEqual(fixture.hotkeyRegistrar.shortcuts.count, 1)
        XCTAssertEqual(fixture.hotkeyRegistrar.activeCount, 0)
        XCTAssertEqual(fixture.hotkeyRegistrar.registrations.first?.unregisterCalls, 1)
    }

    @MainActor func testTwoHostsCannotEraseRegistrationFailureAndExplicitRetryRemainsPossible() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CLAVUNE_RUN_UI_HOST_FIXTURES"] == "1",
                          "Run only in the authorized macOS in-memory UI-host fixture pass")
        let fixture = try CoordinatorFixture()
        let menu = NSHostingView(rootView: DictationView(coordinator: fixture.coordinator))
        let panel = NSHostingView(rootView: DictationView(coordinator: fixture.coordinator))
        fixture.hotkeyRegistrar.failuresRemaining = 1
        menu.rootView.hotkeyEnabledBinding.wrappedValue = true
        let failed = fixture.coordinator.hotkeyStatus
        XCTAssertEqual(failed, "Hotkey-Konflikt oder Registrierung fehlgeschlagen")
        XCTAssertFalse(menu.rootView.hotkeyEnabledBinding.wrappedValue)
        XCTAssertFalse(panel.rootView.hotkeyEnabledBinding.wrappedValue)
        menu.layoutSubtreeIfNeeded(); panel.layoutSubtreeIfNeeded()
        let refreshed = expectation(description: "failed registration update reached later main queue turn")
        DispatchQueue.main.async { refreshed.fulfill() }
        await fulfillment(of: [refreshed], timeout: 2)
        XCTAssertEqual(fixture.coordinator.hotkeyStatus, failed)
        XCTAssertEqual(fixture.hotkeyRegistrar.shortcuts.count, 1)
        XCTAssertEqual(fixture.hotkeyRegistrar.activeCount, 0)
        panel.rootView.hotkeyEnabledBinding.wrappedValue = true
        XCTAssertTrue(menu.rootView.hotkeyEnabledBinding.wrappedValue)
        XCTAssertEqual(fixture.hotkeyRegistrar.shortcuts.count, 2)
        XCTAssertEqual(fixture.hotkeyRegistrar.activeCount, 1)
        menu.rootView.hotkeyEnabledBinding.wrappedValue = false
    }
}
