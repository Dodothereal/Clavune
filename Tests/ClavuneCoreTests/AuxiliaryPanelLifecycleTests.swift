import AppKit
import XCTest
@testable import ClavuneApp
@testable import ClavuneCore

/// Real coordinator/service transitions with a presentation boundary spy. Does not
/// claim actual AppKit window ordering, focus, notification timing or pixel coverage.
final class AuxiliaryPanelLifecycleTests: XCTestCase {
    @MainActor func testNativePanelInitializationStaysHiddenAndPreservesKeyWindow() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CLAVUNE_RUN_UI_HOST_FIXTURES"] == "1",
                          "Run only in the authorized macOS in-memory UI-host fixture pass")
        _ = NSApplication.shared
        let fixture = try CoordinatorFixture()
        let keyWindowBefore = NSApp.keyWindow
        let panelIDsBefore = Set(NSApp.windows.compactMap { $0 as? NSPanel }.map(ObjectIdentifier.init))
        let controller = RecordingPanelController(coordinator: fixture.coordinator)
        let panel = try XCTUnwrap(NSApp.windows.compactMap { $0 as? NSPanel }
            .first { !panelIDsBefore.contains(ObjectIdentifier($0)) },
            "RecordingPanelController must construct its native NSPanel")
        defer { panel.close() }

        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertFalse(panel.isVisible, "Construction must not order the panel onto the desktop")
        XCTAssertFalse(panel.isKeyWindow, "Construction must not turn the hidden panel into a key window")
        XCTAssertTrue(NSApp.keyWindow === keyWindowBefore,
                      "Constructing the auxiliary panel must preserve the current key window")

        controller.hide()
        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertTrue(NSApp.keyWindow === keyWindowBefore)
    }

    @MainActor private final class Panel: RecordingPanelPresenting {
        var forcedShows: [Bool] = []
        var hides = 0
        func show(force: Bool) { forcedShows.append(force) }
        func hide() { hides += 1 }
    }
    @MainActor private func start(_ fixture: CoordinatorFixture) async {
        fixture.coordinator.start()
        let recording = expectation(description: "recording")
        let settled = expectation(description: "startup settled")
        fixture.observePhase(.recording, expectation: recording)
        fixture.observeOperationFinished(settled)
        await fulfillment(of: [recording, settled], timeout: 2)
    }
    @MainActor private func finishCancel(_ fixture: CoordinatorFixture) async {
        fixture.coordinator.cancel()
        let closed = expectation(description: "capture closed")
        fixture.observeCloseFinished(closed)
        await fulfillment(of: [closed], timeout: 2)
    }
    @MainActor func testBusyCloseThenCancelCannotDismissUntilCaptureAcknowledgesClose() async throws {
        let fixture = try CoordinatorFixture(), panel = Panel()
        fixture.coordinator.attachPanel(panel)
        await start(fixture)
        fixture.coordinator.revealPanelIfBusy()
        XCTAssertEqual(panel.forcedShows.last, true)
        fixture.coordinator.hidePanel()
        XCTAssertEqual(panel.hides, 0)
        let enqueued = expectation(description: "cancel enqueued")
        fixture.queue.pause(nextSubmission: enqueued)
        fixture.coordinator.cancel()
        await fulfillment(of: [enqueued], timeout: 2)
        XCTAssertFalse(fixture.coordinator.canHidePanel)
        fixture.coordinator.hidePanel()
        XCTAssertEqual(panel.hides, 0)
        let closed = expectation(description: "cancel acknowledged")
        fixture.observeCloseFinished(closed)
        fixture.queue.resume()
        await fulfillment(of: [closed], timeout: 2)
        XCTAssertTrue(fixture.coordinator.canHidePanel)
        fixture.coordinator.hidePanel()
        XCTAssertEqual(panel.hides, 1)
    }
    @MainActor func testBusyCloseThenPreparationErrorAllowsIdleDismiss() async throws {
        let fixture = try CoordinatorFixture(), panel = Panel()
        fixture.permissionStatus = .denied
        fixture.coordinator.attachPanel(panel)
        fixture.coordinator.start()
        fixture.coordinator.revealPanelIfBusy()
        XCTAssertEqual(panel.forcedShows.last, true)
        fixture.coordinator.hidePanel()
        XCTAssertEqual(panel.hides, 0)
        let settled = expectation(description: "failure settled")
        fixture.observeOperationFinished(settled)
        await fulfillment(of: [settled], timeout: 2)
        XCTAssertEqual(fixture.coordinator.session.phase, .failed)
        XCTAssertTrue(fixture.coordinator.canHidePanel)
        fixture.coordinator.hidePanel()
        XCTAssertEqual(panel.hides, 1)
    }
    @MainActor func testReopenHandoffRequiresVisibleMainAndDoesNotStopRecording() async throws {
        let fixture = try CoordinatorFixture(), panel = Panel()
        fixture.coordinator.attachPanel(panel)
        await start(fixture)
        fixture.coordinator.revealPanelIfBusy()
        fixture.coordinator.handoffPanelToMainWindow(isVisible: false)
        XCTAssertEqual(panel.hides, 0)
        fixture.coordinator.handoffPanelToMainWindow(isVisible: true)
        XCTAssertEqual(panel.hides, 1)
        XCTAssertEqual(fixture.coordinator.session.phase, .recording)
        XCTAssertEqual(fixture.coordinator.microphone.state, .recording)
        XCTAssertEqual(fixture.resources.counts.value.closed, 0)
        await finishCancel(fixture)
    }
    @MainActor func testEmptyReviewStillAllowsAuxiliaryDismissWithoutDiscard() async throws {
        let fixture = try CoordinatorFixture(), panel = Panel()
        fixture.inference.transcript = ""
        fixture.coordinator.attachPanel(panel)
        await start(fixture)
        fixture.coordinator.revealPanelIfBusy()
        fixture.coordinator.stop()
        let review = expectation(description: "empty review")
        fixture.observePhase(.review, expectation: review)
        await fulfillment(of: [review], timeout: 2)
        let settled = expectation(description: "decode settled")
        fixture.observeOperationFinished(settled)
        await fulfillment(of: [settled], timeout: 2)
        XCTAssertTrue(fixture.coordinator.editedText.isEmpty)
        XCTAssertTrue(fixture.coordinator.canHidePanel)
        fixture.coordinator.hidePanel()
        XCTAssertEqual(panel.hides, 1)
        XCTAssertEqual(fixture.coordinator.session.phase, .review)
    }
}
