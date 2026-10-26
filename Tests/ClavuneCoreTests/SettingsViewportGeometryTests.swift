import AppKit
import SwiftUI
import XCTest
@testable import ClavuneApp
@testable import ClavuneCore

/// Independent native-scroll coverage. The existing Settings AX acceptance test
/// remains unchanged and failing; these tests do not observe or certify its
/// language field, final control, accessibility semantics, or visible-window UI.
final class SettingsViewportGeometryTests: UIFixtureAssertions {
    @MainActor func testEnglishNarrowSettingsViewportRoundTrip() async throws {
        try await verifySettingsViewport(language: .english, width: 560)
    }

    @MainActor func testEnglishWideSettingsViewportRoundTrip() async throws {
        try await verifySettingsViewport(language: .english, width: 780)
    }

    @MainActor func testGermanNarrowSettingsViewportRoundTrip() async throws {
        try await verifySettingsViewport(language: .german, width: 560)
    }

    @MainActor func testGermanWideSettingsViewportRoundTrip() async throws {
        try await verifySettingsViewport(language: .german, width: 780)
    }

    private enum FixtureFailure: Error { case layoutTurnNotSettled, unexpectedStatisticsLoad }

    @MainActor private func refresh(_ view: NSView) async throws {
        view.layoutSubtreeIfNeeded()
        let settled = expectation(description: "owned Settings geometry layout turn")
        DispatchQueue.main.async { settled.fulfill() }
        guard await XCTWaiter.fulfillment(of: [settled], timeout: 2) == .completed else {
            XCTFail("A missed layout turn is not measured Settings geometry")
            throw FixtureFailure.layoutTurnNotSettled
        }
        view.layoutSubtreeIfNeeded()
    }

    @MainActor private func navigation(in view: NSView) -> NSSegmentedControl? {
        if let control = view as? NSSegmentedControl, control.segmentCount == 3 { return control }
        for child in view.subviews {
            if let control = navigation(in: child) { return control }
        }
        return nil
    }

    @MainActor private func scrollViews(in view: NSView) -> [NSScrollView] {
        let current = (view as? NSScrollView).map { [$0] } ?? []
        return current + view.subviews.flatMap { scrollViews(in: $0) }
    }

    @MainActor private func assertIsolation(_ fixture: CoordinatorFixture, window: NSWindow,
                                            keyBefore: NSWindow?, mainBefore: NSWindow?) {
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertFalse(window.isMainWindow)
        XCTAssertTrue(NSApp.keyWindow === keyBefore)
        XCTAssertTrue(NSApp.mainWindow === mainBefore)
        XCTAssertEqual(fixture.coordinator.microphone.state, .closed)
        XCTAssertFalse(fixture.coordinator.operationPending)
        XCTAssertFalse(fixture.coordinator.closePending)
        XCTAssertEqual(fixture.resources.counts.value.constructed, 0)
        XCTAssertEqual(fixture.resources.counts.value.opened, 0)
        XCTAssertEqual(fixture.inference.counts.value.loads, 0)
        XCTAssertEqual(fixture.inference.counts.value.decodes, 0)
        XCTAssertEqual(fixture.inference.counts.value.unloads, 0)
        XCTAssertEqual(fixture.permissionCalls, 0)
        XCTAssertEqual(fixture.pickerCalls, 0)
        XCTAssertEqual(fixture.terminationCalls, 0)
        XCTAssertTrue(fixture.hotkeyRegistrar.shortcuts.isEmpty)
        XCTAssertTrue(fixture.clipboard.calls.isEmpty)
    }

    @MainActor private func verifySettingsViewport(language: UILanguage, width: CGFloat) async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CLAVUNE_RUN_UI_HOST_FIXTURES"] == "1",
                          "Run only in the authorized offscreen macOS UI fixture pass")
        _ = NSApplication.shared
        let keyBefore = NSApp.keyWindow, mainBefore = NSApp.mainWindow
        let configuration = try AppLaunchConfiguration.parse(environment: [
            "CLAVUNE_QA_PROFILE": "settings-geometry-" + String(UUID().uuidString.prefix(8)),
            "CLAVUNE_QA_FUNCTIONAL": "synthetic-v1",
        ])
        let fixture = try CoordinatorFixture(launchConfiguration: configuration,
                                             processUsageSnapshot: { nil })
        fixture.coordinator.uiLanguage = language
        let statisticsLoads = FixtureValue(0)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 580),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        // Check the boundaries even if an earlier unwrap or layout wait throws.
        defer {
            XCTAssertEqual(statisticsLoads.value, 0, "Settings must not request a Statistics load")
            assertIsolation(fixture, window: window, keyBefore: keyBefore, mainBefore: mainBefore)
            window.close()
            XCTAssertTrue(NSApp.keyWindow === keyBefore)
            XCTAssertTrue(NSApp.mainWindow === mainBefore)
        }
        let host = NSHostingView(rootView: DictationView(coordinator: fixture.coordinator,
            statisticsLoader: { _ in
                statisticsLoads.update { $0 += 1 }
                throw FixtureFailure.unexpectedStatisticsLoad
            }))
        window.contentView = host
        try await refresh(host)
        let control = try XCTUnwrap(navigation(in: host))
        control.selectedSegment = 1
        XCTAssertTrue(control.sendAction(try XCTUnwrap(control.action), to: control.target))
        try await refresh(host)
        XCTAssertEqual(control.selectedSegment, 1)
        XCTAssertEqual(fixture.coordinator.uiLanguage, language)
        XCTAssertEqual(host.bounds.width, width, accuracy: 1)
        XCTAssertEqual(host.bounds.height, 580, accuracy: 1)

        let scroll = try XCTUnwrap(scrollViews(in: host).first(where: { $0.documentView != nil }))
        XCTAssertTrue(scroll.window === window)
        let clip = scroll.contentView
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertTrue(document.isFlipped,
                      "The top/end oracle requires the actual Settings document's top-down coordinates")
        let navigationFrame = control.convert(control.bounds, to: host)
        let viewportFrame = scroll.convert(scroll.bounds, to: host)
        let documentFrame = document.frame
        let topGap = host.isFlipped
            ? viewportFrame.minY - navigationFrame.maxY
            : navigationFrame.minY - viewportFrame.maxY
        let bottomGap = host.isFlipped
            ? host.bounds.maxY - viewportFrame.maxY
            : viewportFrame.minY - host.bounds.minY
        // Independent agreed layout expectations, not the implementation's token
        // values or a duplicate reconstruction of the Settings content height.
        XCTAssertEqual(topGap, 8, accuracy: 1)
        XCTAssertEqual(bottomGap, 8, accuracy: 1)
        XCTAssertEqual(viewportFrame.minX - host.bounds.minX, 22, accuracy: 1)
        XCTAssertEqual(host.bounds.maxX - viewportFrame.maxX, 22, accuracy: 1)
        XCTAssertEqual(viewportFrame.width, width - 44, accuracy: 1)
        XCTAssertGreaterThan(clip.bounds.height, 0)
        XCTAssertGreaterThan(documentFrame.height, clip.bounds.height,
                             "A non-overflowing fixture cannot prove real end reachability")

        // Derive the destination from AppKit's actual laid-out document, not a
        // guessed row count or a source-derived content-height formula.
        let firstY = documentFrame.minY
        let lastY = documentFrame.maxY - clip.bounds.height
        XCTAssertGreaterThan(lastY, firstY)
        XCTAssertEqual(clip.bounds.minY, firstY, accuracy: 1)
        for offset in [firstY, (firstY + lastY) / 2, lastY, firstY] {
            clip.scroll(to: NSPoint(x: 0, y: offset))
            scroll.reflectScrolledClipView(clip)
            try await refresh(host)
            XCTAssertEqual(clip.bounds.minX, 0, accuracy: 1)
            XCTAssertEqual(clip.bounds.minY, offset, accuracy: 1)
            XCTAssertEqual(document.frame, documentFrame)
            XCTAssertEqual(control.convert(control.bounds, to: host), navigationFrame,
                           "Scrolling Settings must not move the pinned navigation")
            XCTAssertEqual(scroll.convert(scroll.bounds, to: host), viewportFrame,
                           "The viewport must not move or shrink as its document scrolls")
            XCTAssertEqual(control.selectedSegment, 1)
            XCTAssertEqual(fixture.coordinator.uiLanguage, language)
            if offset == lastY {
                XCTAssertEqual(clip.bounds.maxY, document.frame.maxY, accuracy: 1,
                               "Reach the native document's true end, not a masked or clamped substitute")
            }
            assertIsolation(fixture, window: window, keyBefore: keyBefore, mainBefore: mainBefore)
        }
        XCTAssertEqual(clip.bounds.minY, firstY, accuracy: 1,
                       "Returning from the real end must restore the actual top")
    }
}
