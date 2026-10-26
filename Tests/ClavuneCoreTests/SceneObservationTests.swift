import AppKit
import Combine
import SwiftUI
import XCTest
@testable import ClavuneApp

/// The scene's installation observable is intentionally narrower than the live
/// coordinator. This tests the publication boundary, not SwiftUI AppGraph internals.
final class SceneObservationTests: XCTestCase {
    @MainActor private func refresh(_ view: NSView) async {
        view.layoutSubtreeIfNeeded()
        let updated = expectation(description: "offscreen SwiftUI host update turn")
        DispatchQueue.main.async { updated.fulfill() }
        let outcome = await XCTWaiter.fulfillment(of: [updated], timeout: 2)
        XCTAssertEqual(outcome, .completed)
        view.layoutSubtreeIfNeeded()
    }

    @MainActor func testUnrelatedCoordinatorPublicationsDoNotInvalidateSceneInstallation() throws {
        let fixture = try CoordinatorFixture()
        let coordinator = fixture.coordinator!
        let scene = coordinator.scenePresentation
        let main = DictationView(coordinator: coordinator)
        let auxiliary = DictationView(coordinator: coordinator, isAuxiliaryPanel: true)
        XCTAssertTrue(main.coordinator === coordinator)
        XCTAssertTrue(auxiliary.coordinator === coordinator)
        var sceneEvents = 0, contentEvents = 0
        let sceneToken = scene.objectWillChange.sink { sceneEvents += 1 }
        let contentToken = coordinator.objectWillChange.sink { contentEvents += 1 }
        defer { sceneToken.cancel(); contentToken.cancel() }
        coordinator.language = .de
        coordinator.uiLanguage = .german
        coordinator.editedText = "Synthetic UI text"
        coordinator.channel = 1
        coordinator.holdToTalk = false
        XCTAssertEqual(contentEvents, 5, "Content leaves must still receive coordinator updates")
        XCTAssertEqual(sceneEvents, 0, "Recognition/UI updates must not invalidate scene installation")
        XCTAssertTrue(coordinator.scenePresentation === scene)
        XCTAssertTrue(scene.menuBarEnabled)
        XCTAssertEqual(fixture.resources.counts.value.opened, 0)
    }
    @MainActor func testMenuVisibilityAloneUpdatesSceneAndPersistsThroughCoordinator() throws {
        let name = "Clavune.SceneFixture." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "menuBarEnabled")
        let fixture = try CoordinatorFixture(preferences: defaults)
        let coordinator = fixture.coordinator!
        let scene = coordinator.scenePresentation
        XCTAssertFalse(scene.menuBarEnabled)
        var events = 0
        let token = scene.objectWillChange.sink { events += 1 }
        defer { token.cancel() }
        coordinator.menuBarEnabled = false
        XCTAssertEqual(events, 0, "Repeated assignments must not recursively invalidate the scene")
        coordinator.menuBarEnabled = true
        XCTAssertEqual(events, 1)
        XCTAssertTrue(scene.menuBarEnabled)
        XCTAssertEqual(defaults.object(forKey: "menuBarEnabled") as? Bool, true)
        coordinator.menuBarEnabled = true
        XCTAssertEqual(events, 1)
        coordinator.menuBarEnabled = false
        XCTAssertEqual(events, 2)
        XCTAssertFalse(scene.menuBarEnabled)
        XCTAssertEqual(defaults.object(forKey: "menuBarEnabled") as? Bool, false)
        let reopened = try CoordinatorFixture(preferences: defaults)
        XCTAssertFalse(reopened.coordinator.scenePresentation.menuBarEnabled)
    }

    @MainActor func testOffscreenSyntheticHostBurstKeepsSceneInstallationNarrow() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CLAVUNE_RUN_UI_HOST_FIXTURES"] == "1",
                          "Run only in the authorized macOS in-memory UI-host fixture pass")
        _ = NSApplication.shared
        let fixture = try CoordinatorFixture(processUsageSnapshot: { nil })
        let coordinator = fixture.coordinator!
        let scene = coordinator.scenePresentation
        let keyWindowBefore = NSApp.keyWindow
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: DictationView(coordinator: coordinator)
            .transaction { $0.disablesAnimations = true; $0.animation = nil })
        window.contentView = host

        var sceneEvents = 0
        var contentEvents = 0
        let sceneToken = scene.objectWillChange.sink { sceneEvents += 1 }
        let contentToken = coordinator.objectWillChange.sink { contentEvents += 1 }
        defer { sceneToken.cancel(); contentToken.cancel() }
        await refresh(host)

        // Exercise real SwiftUI layout with a synthetic coordinator only. No
        // capture, model load, inference, user document, clipboard or visible window.
        for index in 0..<32 {
            coordinator.language = index.isMultiple(of: 2) ? .de : .en
            coordinator.uiLanguage = index.isMultiple(of: 2) ? .german : .english
            coordinator.editedText = "Synthetic layout state \(index)"
            coordinator.channel = (index + 1) % 32
            coordinator.holdToTalk = !index.isMultiple(of: 2)
            await refresh(host)
        }

        XCTAssertEqual(contentEvents, 160, "Mounted content must receive every synthetic state publication")
        XCTAssertEqual(sceneEvents, 0, "Content-state bursts must not republish menu-bar installation state")
        XCTAssertEqual(fixture.resources.counts.value.opened, 0)
        XCTAssertEqual(fixture.inference.counts.value.loads, 0)
        XCTAssertEqual(fixture.inference.counts.value.decodes, 0)
        XCTAssertEqual(fixture.inference.counts.value.unloads, 0)
        XCTAssertEqual(coordinator.microphone.state, .closed)
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(NSApp.keyWindow === keyWindowBefore, "The offscreen host must not change desktop focus")
    }
}
