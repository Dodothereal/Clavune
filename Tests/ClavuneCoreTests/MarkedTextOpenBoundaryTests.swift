import AppKit
import SwiftUI
import XCTest
@testable import ClavuneApp
@testable import ClavuneCore

/// Actual native marked text must survive every rejected Open outcome.
/// Only document/resource boundaries are fake; editor/delegate/binding are real.
final class MarkedTextOpenBoundaryTests: UIFixtureAssertions {
    private enum Failure: Error { case readerTimedOut, unexpectedStatisticsLoad }
    private enum Outcome { case decline, readFailure, cancel }

    @MainActor private func editor(in view: NSView) -> PlainTranscriptTextView? {
        if let editor = view as? PlainTranscriptTextView { return editor }
        for child in view.subviews { if let found = editor(in: child) { return found } }
        return nil
    }

    @MainActor private func refresh(_ view: NSView) async {
        view.layoutSubtreeIfNeeded()
        let settled = expectation(description: "owned Open diagnostic layout turn")
        DispatchQueue.main.async { settled.fulfill() }
        await fulfillment(of: [settled], timeout: 2)
        view.layoutSubtreeIfNeeded()
    }

    @MainActor func testDeclinedOpenPreservesCompositionSelectionAndUndo() async throws {
        try await checkPreservation(outcome: .decline)
    }
    @MainActor func testFailedReadPreservesCompositionSelectionAndUndo() async throws {
        try await checkPreservation(outcome: .readFailure)
    }
    @MainActor func testCancelledOpenRejectsLateTextAndPreservesCompositionSelectionAndUndo() async throws {
        try await checkPreservation(outcome: .cancel)
    }
    @MainActor private func checkPreservation(outcome: Outcome) async throws {
        guard ProcessInfo.processInfo.environment["CLAVUNE_RUN_UI_HOST_FIXTURES"] == "1" else {
            XCTFail("Requires authorized offscreen native UI fixtures")
            return
        }
        _ = NSApplication.shared
        let keyBefore = NSApp.keyWindow, mainBefore = NSApp.mainWindow
        let configuration = try AppLaunchConfiguration.parse(environment: [
            "CLAVUNE_QA_PROFILE": "ime-open-" + String(UUID().uuidString.prefix(8)),
            "CLAVUNE_QA_FUNCTIONAL": "synthetic-v1",
        ])
        let original = "Synthetic saved review."
        let composition = " composition"
        let selected = URL(fileURLWithPath: "/synthetic-ime-open-never-opened.txt")
        let reads = FixtureValue(0), confirmations = FixtureValue(0)
        let timedOut = FixtureValue(false), statisticsLoads = FixtureValue(0)
        let entered = XCTestExpectation(description: "held synthetic Open reader entered")
        let exited = XCTestExpectation(description: "held synthetic Open reader exited")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let fixture = try CoordinatorFixture(launchConfiguration: configuration,
            processUsageSnapshot: { nil }, configureEnvironment: { environment in
                environment.chooseTranscriptToOpen = { _ in selected }
                environment.readTranscript = { _ in
                    reads.update { $0 += 1 }
                    if reads.value == 1 { return original }
                    entered.fulfill()
                    defer { exited.fulfill() }
                    guard gate.wait(timeout: .now() + 5) == .success else {
                        timedOut.value = true
                        throw Failure.readerTimedOut
                    }
                    if outcome == .readFailure { throw TranscriptFileStore.Failure.invalidUTF8 }
                    return "Synthetic replacement must not be installed."
                }
                environment.confirmTranscriptReplacement = { _ in
                    confirmations.update { $0 += 1 }
                    return false
                }
            })
        fixture.coordinator.openTranscript()
        await waitForOperation(fixture)
        XCTAssertEqual(fixture.coordinator.editedText, original)
        XCTAssertFalse(fixture.coordinator.hasUnsavedReview)
        let reviewID = fixture.coordinator.session.id
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 580),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer {
            XCTAssertFalse(window.isVisible)
            XCTAssertTrue(NSApp.keyWindow === keyBefore)
            XCTAssertTrue(NSApp.mainWindow === mainBefore)
            XCTAssertFalse(timedOut.value)
            XCTAssertEqual(statisticsLoads.value, 0)
            XCTAssertEqual(fixture.coordinator.microphone.state, .closed)
            XCTAssertFalse(fixture.coordinator.operationPending)
            XCTAssertFalse(fixture.coordinator.closePending)
            XCTAssertEqual(fixture.resources.counts.value.constructed, 0)
            XCTAssertEqual(fixture.resources.counts.value.opened, 0)
            XCTAssertEqual(fixture.inference.counts.value.loads, 0)
            XCTAssertEqual(fixture.inference.counts.value.decodes, 0)
            XCTAssertEqual(fixture.permissionCalls, 0)
            XCTAssertEqual(fixture.terminationCalls, 0)
            XCTAssertTrue(fixture.clipboard.calls.isEmpty)
            window.close()
        }
        let host = NSHostingView(rootView: DictationView(coordinator: fixture.coordinator,
            statisticsLoader: { _ in
                statisticsLoads.update { $0 += 1 }
                throw Failure.unexpectedStatisticsLoad
            }))
        window.contentView = host
        await refresh(host)
        let editor = try XCTUnwrap(editor(in: host))
        XCTAssertTrue(editor.isEditable)
        XCTAssertTrue(window.makeFirstResponder(editor))
        let undo = try XCTUnwrap(editor.undoManager)
        undo.beginUndoGrouping()
        editor.insertText(" prior 👋🏽", replacementRange: NSRange(location: (editor.string as NSString).length, length: 0))
        undo.endUndoGrouping()
        await refresh(host)
        XCTAssertTrue(undo.canUndo)
        let bound = fixture.coordinator.editedText
        let expected = bound + composition
        editor.setMarkedText(composition,
            selectedRange: NSRange(location: (composition as NSString).length, length: 0),
            replacementRange: NSRange(location: (editor.string as NSString).length, length: 0))
        guard editor.hasMarkedText(), Data(editor.string.utf8) == Data(expected.utf8),
              Data(fixture.coordinator.editedText.utf8) == Data(bound.utf8) else {
            XCTFail("Genuine native marked-text/binding divergence was not established")
            return
        }
        let selection = editor.selectedRange()
        XCTAssertEqual(selection, NSRange(location: (expected as NSString).length, length: 0))
        fixture.coordinator.openTranscript()
        guard await XCTWaiter.fulfillment(of: [entered], timeout: 2) == .completed else {
            gate.signal(); await waitForOperation(fixture)
            XCTFail("Open did not enter the held reader")
            return
        }
        await refresh(host)
        let heldNative = editor.string, heldBound = fixture.coordinator.editedText
        let heldEditable = editor.isEditable, heldMarked = editor.hasMarkedText()
        let heldPending = fixture.coordinator.transcriptFilePending
        let heldUndo = editor.undoManager?.canUndo ?? false
        let heldSelection = editor.selectedRange()
        if outcome == .cancel { fixture.coordinator.cancel() }
        gate.signal()
        await fulfillment(of: [exited], timeout: 2)
        await waitForOperation(fixture)
        await refresh(host)
        let after = try XCTUnwrap(self.editor(in: host))
        XCTAssertEqual(reads.value, 2)
        XCTAssertEqual(confirmations.value, outcome == .decline ? 1 : 0)
        XCTAssertTrue(heldPending)
        XCTAssertFalse(heldEditable)
        XCTAssertFalse(heldMarked)
        XCTAssertTrue(heldUndo)
        XCTAssertEqual(heldSelection, selection)
        XCTAssertEqual(Data(heldBound.utf8), Data(expected.utf8))
        XCTAssertEqual(fixture.coordinator.session.id, reviewID)
        XCTAssertTrue(after === editor)
        XCTAssertEqual(Data(heldNative.utf8), Data(expected.utf8), "Open must retain genuine pending composition during the disabled refresh")
        XCTAssertEqual(Data(after.string.utf8), Data(expected.utf8), "Rejected Open must retain the entire native draft")
        XCTAssertEqual(Data(fixture.coordinator.editedText.utf8), Data(expected.utf8))
        XCTAssertTrue(fixture.coordinator.hasUnsavedReview)
        XCTAssertFalse(after.hasMarkedText())
        XCTAssertTrue(after.isEditable)
        XCTAssertTrue(after.undoManager === undo)
        XCTAssertTrue(undo.canUndo)
        XCTAssertEqual(after.selectedRange(), selection)
        undo.undo()
        await refresh(host)
        XCTAssertEqual(Data(after.string.utf8), Data(bound.utf8))
        XCTAssertEqual(Data(fixture.coordinator.editedText.utf8), Data(bound.utf8))
        XCTAssertEqual(after.selectedRange(), NSRange(location: (bound as NSString).length, length: 0))
        XCTAssertTrue(fixture.coordinator.hasUnsavedReview, "The earlier edit remains dirty")
        XCTAssertTrue(undo.canRedo)
        undo.redo()
        await refresh(host)
        XCTAssertEqual(Data(after.string.utf8), Data(expected.utf8))
        XCTAssertEqual(Data(fixture.coordinator.editedText.utf8), Data(expected.utf8))
        XCTAssertEqual(after.selectedRange(), selection)
        XCTAssertTrue(fixture.coordinator.hasUnsavedReview)
        XCTAssertTrue(after.undoManager === undo)
    }
}
