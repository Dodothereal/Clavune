import AppKit
import XCTest
@testable import ClavuneApp
@testable import ClavuneCore

final class QAAdaptiveWindowSizeTests: XCTestCase {
    func testOnlyQAIdleAndEmptyStatisticsUseCompactHeight() {
        func height(_ phase: SessionPhase, busy: Bool = false,
                    settings: Bool = false, statistics: Bool = false,
                    qa: Bool = true, panel: Bool = false,
                    reviewBytes: Int = 0) -> CGFloat? {
            QAWindowLayout.contentHeight(isQA: qa, isAuxiliaryPanel: panel,
                settingsVisible: settings, statisticsVisible: statistics,
                phase: phase, busy: busy, reviewUTF8Bytes: reviewBytes)
        }
        XCTAssertEqual(height(.idle), 200)
        XCTAssertEqual(height(.idle, settings: true, statistics: true), 200)
        XCTAssertEqual(height(.review, settings: true, statistics: true), 200)
        XCTAssertEqual(QAWindowLayout.contentHeight(isQA: true, isAuxiliaryPanel: false,
            settingsVisible: true, statisticsVisible: true, statisticsPreview: true,
            phase: .idle, busy: false), 580)
        XCTAssertEqual(QAWindowLayout.contentHeight(isQA: true, isAuxiliaryPanel: false,
            settingsVisible: true, statisticsVisible: true, statisticsPreview: true,
            statisticsPreviewHasOneSource: true, phase: .idle, busy: false), 420)
        XCTAssertEqual(height(.idle, settings: true), 580)
        XCTAssertEqual(height(.idle, busy: true), 580)
        XCTAssertEqual(height(.review), 360)
        XCTAssertEqual(height(.review, reviewBytes: 180), 360)
        XCTAssertEqual(height(.review, reviewBytes: 181), 440)
        XCTAssertEqual(height(.review, reviewBytes: 1_200), 440)
        XCTAssertEqual(height(.review, reviewBytes: 1_201), 580)
        XCTAssertEqual(QAWindowLayout.reviewSize(forUTF8Bytes: 100).editor, 96)
        XCTAssertEqual(QAWindowLayout.reviewSize(forUTF8Bytes: 400).editor, 180)
        XCTAssertEqual(QAWindowLayout.reviewSize(forUTF8Bytes: 2_000).editor, 336)
        XCTAssertEqual(height(.failed), 580)
        XCTAssertEqual(height(.cancelled), 580)
        XCTAssertNil(height(.idle, qa: false))
        XCTAssertNil(height(.idle, panel: true))
    }

    @MainActor func testHiddenMainWindowKeepsTopAndWidthAcrossModeChanges() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CLAVUNE_RUN_UI_HOST_FIXTURES"] == "1",
                          "Run only in the authorized offscreen macOS UI fixture pass")
        _ = NSApplication.shared
        for sceneIdentifier in ["main", "clavune.main"] {
            let window = NSWindow(contentRect: NSRect(x: 150, y: 280, width: 780, height: 300),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.identifier = NSUserInterfaceItemIdentifier(sceneIdentifier)
            let sizing = QAAdaptiveWindowSize.SizingView(contentHeight: 300)
            window.contentView = sizing
            await advanceMainTurn()
            let original = window.frame
            XCTAssertEqual(window.contentRect(forFrameRect: original).height, 300, accuracy: 1)

            sizing.request(580)
            await advanceMainTurn()
            XCTAssertEqual(window.contentRect(forFrameRect: window.frame).height, 580, accuracy: 1)
            XCTAssertEqual(window.frame.minX, original.minX, accuracy: 1)
            XCTAssertEqual(window.frame.width, original.width, accuracy: 1)
            XCTAssertEqual(window.frame.maxY, original.maxY, accuracy: 1)

            sizing.request(300)
            await advanceMainTurn()
            XCTAssertEqual(window.contentRect(forFrameRect: window.frame).height, 300, accuracy: 1)
            XCTAssertEqual(window.frame.maxY, original.maxY, accuracy: 1)
            XCTAssertFalse(window.isVisible)
            window.close()
        }
    }

    @MainActor func testUnrelatedWindowIsNotResized() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CLAVUNE_RUN_UI_HOST_FIXTURES"] == "1",
                          "Run only in the authorized offscreen macOS UI fixture pass")
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 150, y: 280, width: 780, height: 300),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("unrelated.fixture")
        defer { window.close() }
        let original = window.frame
        window.contentView = QAAdaptiveWindowSize.SizingView(contentHeight: 580, preferredWidth: 560)
        await advanceMainTurn()
        XCTAssertEqual(window.frame, original)
        XCTAssertFalse(window.isVisible)
    }

    @MainActor func testHiddenQAWindowChangesOnlyItsOwnWidthOnExplicitRequest() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CLAVUNE_RUN_UI_HOST_FIXTURES"] == "1",
                          "Run only in the authorized offscreen macOS UI fixture pass")
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 150, y: 280, width: 780, height: 460),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("clavune.main")
        defer { window.close() }
        let sizing = QAAdaptiveWindowSize.SizingView(contentHeight: 460)
        window.contentView = sizing
        await advanceMainTurn()
        let original = window.frame
        sizing.request(460, preferredWidth: 560)
        await advanceMainTurn()
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).width, 560, accuracy: 1)
        XCTAssertEqual(window.frame.minX, original.minX, accuracy: 1)
        XCTAssertEqual(window.frame.maxY, original.maxY, accuracy: 1)
        sizing.request(460, preferredWidth: 780)
        await advanceMainTurn()
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).width, 780, accuracy: 1)
        XCTAssertFalse(window.isVisible)
    }

    @MainActor private func advanceMainTurn() async {
        let queued = expectation(description: "one main-queue sizing turn")
        DispatchQueue.main.async { queued.fulfill() }
        await fulfillment(of: [queued], timeout: 2)
    }
}
