import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import ClavuneApp

@MainActor private final class NavigationBindingProbe {
    var settings = false
    var statistics = false
    var admittedAtWrite: [Int?] = []
    weak var coordinator: ObservatoryNavigationSegments.Coordinator?
}

/// Offscreen AppKit fixture: synthetic labels only, no visible app or input.
/// Evidence level: deterministic model/action inspection. No presentation-frame
/// sampling, live animation calibration, frame-rate, or smoothness claim.
final class ObservatoryNavigationMotionTests: XCTestCase {
    @MainActor func testAppLocalReducedMotionDefaultAndWritableOverride() {
        var environment = EnvironmentValues()
        let systemPreference = environment.accessibilityReduceMotion
        XCTAssertFalse(environment.observatoryForceReducedMotion)
        environment.observatoryForceReducedMotion = true
        XCTAssertTrue(environment.observatoryForceReducedMotion)
        XCTAssertEqual(environment.accessibilityReduceMotion, systemPreference,
                       "The local seam must not mutate the system accessibility preference")
        environment.observatoryForceReducedMotion = false
        XCTAssertFalse(environment.observatoryForceReducedMotion)
        XCTAssertEqual(environment.accessibilityReduceMotion, systemPreference)
    }

    @MainActor func testSelectionAdmissionSpansBothSynchronousBindingWrites() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CLAVUNE_RUN_UI_HOST_FIXTURES"] == "1",
                          "Run only in the authorized offscreen macOS UI fixture pass")
        _ = NSApplication.shared
        let probe = NavigationBindingProbe()
        let settings = Binding(get: { probe.settings }, set: {
            probe.settings = $0
            probe.admittedAtWrite.append(probe.coordinator?.admittedSelectionIndex)
        })
        let statistics = Binding(get: { probe.statistics }, set: {
            probe.statistics = $0
            probe.admittedAtWrite.append(probe.coordinator?.admittedSelectionIndex)
        })
        let navigation = ObservatoryNavigationSegments(settingsVisible: settings,
            statisticsVisible: statistics, accessibilityTitle: "View", dictationTitle: "Dictation",
            settingsTitle: "Settings", statisticsTitle: "Statistics")
        let coordinator = navigation.makeCoordinator()
        probe.coordinator = coordinator
        let control = InkSegmentedControl(labels: ["Dictation", "Settings", "Statistics"],
                                          trackingMode: .selectOne, target: nil, action: nil)
        control.selectedSegment = 2
        coordinator.selectionChanged(control)
        XCTAssertEqual(probe.admittedAtWrite, [2, 2])
        XCTAssertTrue(probe.settings)
        XCTAssertTrue(probe.statistics)
        XCTAssertNil(coordinator.admittedSelectionIndex)

        // Repeated/alternating actions use the production synchronous binding
        // transaction; a stale admitted selection must not leak to the next one.
        for index in [2, 1, 0, 2, 0] {
            probe.admittedAtWrite.removeAll()
            control.selectedSegment = index
            coordinator.selectionChanged(control)
            XCTAssertEqual(probe.admittedAtWrite, [index, index])
            XCTAssertEqual(probe.settings, index != 0)
            XCTAssertEqual(probe.statistics, index == 2)
            XCTAssertNil(coordinator.admittedSelectionIndex)
        }
        probe.admittedAtWrite.removeAll()
        control.selectedSegment = -1
        coordinator.selectionChanged(control)
        XCTAssertTrue(probe.admittedAtWrite.isEmpty)
        XCTAssertFalse(probe.settings)
        XCTAssertFalse(probe.statistics)
    }

    @MainActor func testSelectionInkAnimatesOnlyForEventsAndHonorsReduceMotion() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CLAVUNE_RUN_UI_HOST_FIXTURES"] == "1",
                          "Run only in the authorized offscreen macOS UI fixture pass")
        _ = NSApplication.shared
        let keyBefore = NSApp.keyWindow, mainBefore = NSApp.mainWindow
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 44),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let control = InkSegmentedControl(labels: ["Dictation", "Settings", "Statistics"],
                                          trackingMode: .selectOne, target: nil, action: nil)
        window.contentView = control
        control.selectedSegment = 0
        control.layoutSubtreeIfNeeded()
        control.moveUnderline(animated: false)
        let underline = try XCTUnwrap(control.layer?.sublayers?.first {
            $0.name == "clavune.navigation.underline"
        })
        underline.speed = 0 // Deterministic inspection; no renderer timing or sleep.
        XCTAssertEqual(control.focusRingType, .none)
        XCTAssertNil(underline.animation(forKey: "clavune.selection"))
        XCTAssertEqual(underline.frame.height, 2, accuracy: 0.1)
        XCTAssertTrue(window.makeFirstResponder(control))
        XCTAssertEqual(underline.frame.height, 3, accuracy: 0.1,
                       "Keyboard focus should strengthen the selected underline")
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertEqual(underline.frame.height, 2, accuracy: 0.1)

        control.selectedSegment = 1
        control.moveUnderline(animated: true)
        let event = try XCTUnwrap(underline.animation(forKey: "clavune.selection") as? CABasicAnimation)
        XCTAssertEqual(event.keyPath, "position.x")
        XCTAssertEqual(event.duration, 0.14, accuracy: 0.001)
        XCTAssertEqual(event.repeatCount, 0)
        XCTAssertEqual(underline.frame.midX, 180, accuracy: 1)

        // A progress publication or layout pass must not restart the action.
        let marker = try XCTUnwrap(event.copy() as? CABasicAnimation)
        marker.duration = 17
        underline.add(marker, forKey: "clavune.selection")
        control.layout()
        control.moveUnderline(animated: false)
        XCTAssertEqual(underline.animation(forKey: "clavune.selection")?.duration, 17)

        control.selectedSegment = 2
        control.moveUnderline(animated: true)
        XCTAssertEqual(underline.animation(forKey: "clavune.selection")?.duration, 0.14)
        XCTAssertEqual(underline.frame.midX, 300, accuracy: 1)

        control.selectedSegment = -1 // No active tab: retire obsolete motion.
        control.moveUnderline(animated: false)
        XCTAssertNil(underline.animation(forKey: "clavune.selection"))
        XCTAssertTrue(underline.isHidden)
        control.selectedSegment = 2
        control.moveUnderline(animated: false)
        XCTAssertFalse(underline.isHidden)

        control.reducedMotion = true
        XCTAssertNil(underline.animation(forKey: "clavune.selection"))
        control.selectedSegment = 0
        control.moveUnderline(animated: true)
        XCTAssertNil(underline.animation(forKey: "clavune.selection"))
        XCTAssertEqual(underline.frame.midX, 60, accuracy: 1)

        control.reducedMotion = false
        control.selectedSegment = 1
        control.moveUnderline(animated: false) // Programmatic selection snaps.
        XCTAssertNil(underline.animation(forKey: "clavune.selection"))
        XCTAssertEqual(underline.frame.midX, 180, accuracy: 1)
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(NSApp.keyWindow === keyBefore)
        XCTAssertTrue(NSApp.mainWindow === mainBefore)
    }

    @MainActor func testInterruptedSelectionResizeAndTeardownRetireObsoleteActions() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CLAVUNE_RUN_UI_HOST_FIXTURES"] == "1",
                          "Run only in the authorized offscreen macOS UI fixture pass")
        _ = NSApplication.shared
        let keyBefore = NSApp.keyWindow, mainBefore = NSApp.mainWindow
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 44),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let control = InkSegmentedControl(labels: ["Dictation", "Settings", "Statistics"],
                                          trackingMode: .selectOne, target: nil, action: nil)
        window.contentView = control
        control.selectedSegment = 0
        control.layoutSubtreeIfNeeded()
        control.moveUnderline(animated: false)
        let underline = try XCTUnwrap(control.layer?.sublayers?.first {
            $0.name == "clavune.navigation.underline"
        })
        underline.speed = 0 // Inspect installed actions, not compositor timing.
        for (index, destination) in [(1, 180.0), (2, 300.0), (0, 60.0)] {
            control.selectedSegment = index
            control.moveUnderline(animated: true)
            if let action = underline.animation(forKey: "clavune.selection") as? CABasicAnimation {
                XCTAssertEqual(action.duration, 0.14, accuracy: 0.001)
                XCTAssertEqual(try XCTUnwrap(action.toValue as? NSNumber).doubleValue, destination, accuracy: 1)
                XCTAssertTrue(try XCTUnwrap(action.fromValue as? NSNumber).doubleValue.isFinite)
                XCTAssertEqual(underline.animationKeys(), ["clavune.selection"])
            } else {
                // A rapid return to the still-current presentation position may
                // legitimately need no new animation; never invent an intermediate.
                XCTAssertNil(underline.animationKeys())
            }
            XCTAssertEqual(Double(underline.frame.midX), destination, accuracy: 1)
        }

        control.setFrameSize(NSSize(width: 450, height: 44))
        control.layout()
        XCTAssertEqual(underline.frame.midX, 75, accuracy: 1)
        XCTAssertNil(underline.animation(forKey: "clavune.selection"),
                     "Resizing must not leave an action targeting obsolete geometry")
        control.selectedSegment = 2
        control.moveUnderline(animated: true)
        XCTAssertNotNil(underline.animation(forKey: "clavune.selection"))
        control.reducedMotion = true // Mid-action preference change is immediate.
        XCTAssertNil(underline.animationKeys())
        for index in [0, 2, 1, 1] {
            control.selectedSegment = index
            control.moveUnderline(animated: true)
            XCTAssertNil(underline.animationKeys())
            XCTAssertEqual(underline.frame.midX, CGFloat(index) * 150 + 75, accuracy: 1)
        }
        control.reducedMotion = false
        control.selectedSegment = 2
        control.moveUnderline(animated: true)
        // Install a cleanup sentinel, not a claimed production animation frame.
        underline.add(CABasicAnimation(keyPath: "opacity"), forKey: "test.teardown-sentinel")
        control.tearDown()
        control.tearDown() // Repeated dismissal is harmless.
        XCTAssertNil(underline.animationKeys())
        XCTAssertNil(underline.superlayer)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertFalse(window.isMainWindow)
        XCTAssertTrue(NSApp.keyWindow === keyBefore)
        XCTAssertTrue(NSApp.mainWindow === mainBefore)
    }
}
