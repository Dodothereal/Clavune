import AppKit
import SwiftUI
import XCTest
@testable import ClavuneApp
@testable import ClavuneCore

/// Opt-in native readiness regressions. Hosts remain offscreen; text and services are synthetic.
final class ReviewNavigationReadinessTests: UIFixtureAssertions {
    @MainActor private func editor(in view: NSView) -> PlainTranscriptTextView? {
        if let editor = view as? PlainTranscriptTextView, editor.isEditable { return editor }
        for child in view.subviews {
            if let found = editor(in: child) { return found }
        }
        return nil
    }

    @MainActor private func navigation(in view: NSView) -> NSSegmentedControl? {
        if let control = view as? NSSegmentedControl, [2, 3].contains(control.segmentCount),
           ["Dictation", "Diktat"].contains(control.label(forSegment: 0) ?? ""),
           ["Settings", "Einstellungen"].contains(control.label(forSegment: 1) ?? "") {
            return control
        }
        for child in view.subviews {
            if let found = navigation(in: child) { return found }
        }
        return nil
    }

    @MainActor private func refresh(_ host: NSView) async {
        host.layoutSubtreeIfNeeded()
        let updated = expectation(description: "native host update turn")
        DispatchQueue.main.async { updated.fulfill() }
        await fulfillment(of: [updated], timeout: 2)
        host.layoutSubtreeIfNeeded()
    }

    @MainActor private func select(_ index: Int, in host: NSView) async throws {
        // Fail clearly if this SDK renders the Picker differently; missing native
        // controls are invalid fixture evidence, not a killed production regression.
        let control = try XCTUnwrap(navigation(in: host), "Native Dictation/Settings picker not found")
        XCTAssertTrue(control.isEnabled)
        let action = try XCTUnwrap(control.action, "Native navigation control has no action")
        control.selectedSegment = index
        XCTAssertTrue(control.sendAction(action, to: control.target), "Native navigation action not delivered")
        await refresh(host)
    }

    @MainActor func testNavigationPickerHasLocalizedAccessibilityLabel() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CLAVUNE_RUN_UI_HOST_FIXTURES"] == "1",
                          "Run only in the authorized macOS in-memory UI-host fixture pass")
        _ = NSApplication.shared
        let fixture = try CoordinatorFixture()
        fixture.coordinator.uiLanguage = .english
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: DictationView(coordinator: fixture.coordinator))
        window.contentView = host
        await refresh(host)

        let english = try XCTUnwrap(navigation(in: host), "Native navigation picker missing in English")
        XCTAssertEqual(english.accessibilityLabel(), "View")
        XCTAssertEqual(english.label(forSegment: 0), "Dictation")
        XCTAssertEqual(english.label(forSegment: 1), "Settings")
        XCTAssertEqual(english.segmentCount, 3)
        XCTAssertEqual(english.label(forSegment: 2), "Statistics")
        XCTAssertEqual(english.selectedSegment, 0)

        fixture.coordinator.uiLanguage = .german
        await refresh(host)
        let german = try XCTUnwrap(navigation(in: host), "Native navigation picker missing in German")
        XCTAssertEqual(german.accessibilityLabel(), "Ansicht")
        XCTAssertEqual(german.label(forSegment: 0), "Diktat")
        XCTAssertEqual(german.label(forSegment: 1), "Einstellungen")
        XCTAssertEqual(german.segmentCount, 3)
        XCTAssertEqual(german.label(forSegment: 2), "Statistiken")
        XCTAssertEqual(german.selectedSegment, 0, "Changing interface language must not change the selected view")
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(fixture.clipboard.calls.isEmpty)
    }

    @MainActor func testSettingsRoundTripPreservesPendingReviewUndoAndRedo() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CLAVUNE_RUN_UI_HOST_FIXTURES"] == "1",
                          "Run only in the authorized macOS in-memory UI-host fixture pass")
        _ = NSApplication.shared
        try await verifySettingsRoundTrip(isAuxiliaryPanel: false)
        try await verifySettingsRoundTrip(isAuxiliaryPanel: true)
    }

    @MainActor func testEnteringSettingsFromAnotherControlMovesFocusToPersistentNavigation() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CLAVUNE_RUN_UI_HOST_FIXTURES"] == "1",
                          "Run only in the authorized macOS in-memory UI-host fixture pass")
        _ = NSApplication.shared
        let keyWindowBefore = NSApp.keyWindow
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let originReference = FocusOriginReference()
        let host = NSHostingView(rootView: FocusOriginHandoffFixture(origin: originReference)
            .transaction { $0.disablesAnimations = true; $0.animation = nil })
        window.contentView = host
        await refresh(host)

        // The native button is hosted inside the same SwiftUI view and is hidden
        // by the Settings state changed through the real navigation action.
        let focusOrigin = try XCTUnwrap(originReference.button)
        XCTAssertFalse(focusOrigin.isHidden)
        XCTAssertTrue(window.makeFirstResponder(focusOrigin))
        let navigation = try XCTUnwrap(navigation(in: host))
        let action = try XCTUnwrap(navigation.action)
        navigation.selectedSegment = 1
        XCTAssertTrue(navigation.sendAction(action, to: navigation.target))
        await refresh(host)

        XCTAssertEqual(navigation.selectedSegment, 1, "The native picker must open Settings")
        XCTAssertTrue(focusOrigin.isHidden, "The content responder must be hidden by the Settings transition")
        XCTAssertTrue(window.firstResponder === navigation,
                      "Keyboard focus must move to the still-visible navigation after its content responder is hidden")
        XCTAssertFalse(window.isVisible, "The fixture must not appear on the desktop")
        XCTAssertTrue(NSApp.keyWindow === keyWindowBefore, "The fixture must not change the desktop key window")
    }

    @MainActor func testSettingsTransitionCommitsMarkedReviewTextBeforeHidingEditor() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CLAVUNE_RUN_UI_HOST_FIXTURES"] == "1",
                          "Run only in the authorized macOS in-memory UI-host fixture pass")
        _ = NSApplication.shared
        let selected = URL(fileURLWithPath: "/synthetic-ime-review-never-opened.txt")
        let fixture = try CoordinatorFixture(configureEnvironment: { environment in
            environment.chooseTranscriptToOpen = { _ in selected }
            environment.readTranscript = { _ in "Review" }
        })
        fixture.coordinator.openTranscript(); await waitForOperation(fixture)
        let reviewID = fixture.coordinator.session.id
        let keyWindowBefore = NSApp.keyWindow
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: DictationView(coordinator: fixture.coordinator)
            .transaction { $0.disablesAnimations = true; $0.animation = nil })
        window.contentView = host
        await refresh(host)

        let reviewEditor = try XCTUnwrap(editor(in: host))
        let navigationControl = try XCTUnwrap(navigation(in: host))
        XCTAssertTrue(window.makeFirstResponder(reviewEditor))
        let insertion = (reviewEditor.string as NSString).length
        reviewEditor.setSelectedRange(NSRange(location: insertion, length: 0))
        let originalSelection = reviewEditor.selectedRange()
        let composition = " composition"
        reviewEditor.setMarkedText(composition,
            selectedRange: NSRange(location: (composition as NSString).length, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(reviewEditor.hasMarkedText(), "The fixture must begin with an active native marked-text composition")
        let committedSelection = reviewEditor.selectedRange()

        try await select(1, in: host)
        XCTAssertFalse(reviewEditor.hasMarkedText(), "Leaving the editor must end its native marked-text composition")
        XCTAssertFalse(window.firstResponder === reviewEditor, "The hidden editor must not retain keyboard focus")
        XCTAssertTrue(window.firstResponder === navigationControl,
                      "The persistent navigation owns focus after the review editor hides")
        XCTAssertEqual(reviewEditor.string, "Review composition")
        XCTAssertEqual(fixture.coordinator.editedText, "Review composition",
                       "Ending composition while hiding the editor must publish its final text")
        XCTAssertEqual(fixture.coordinator.session.id, reviewID)
        XCTAssertEqual(navigationControl.selectedSegment, 1)

        try await select(0, in: host)
        let returned = try XCTUnwrap(self.editor(in: host))
        XCTAssertTrue(returned === reviewEditor)
        XCTAssertEqual(returned.string, "Review composition")
        XCTAssertEqual(fixture.coordinator.editedText, "Review composition")
        XCTAssertEqual(fixture.coordinator.session.id, reviewID)
        XCTAssertEqual(returned.selectedRange(), committedSelection,
                       "Returning to Dictation preserves the committed composition selection")
        let undo = try XCTUnwrap(returned.undoManager)
        XCTAssertTrue(undo.canUndo, "Committing marked text during navigation must remain undoable")
        guard undo.canUndo else { return }
        undo.undo()
        XCTAssertEqual(returned.string, "Review", "Undo must remove the committed IME composition")
        XCTAssertEqual(fixture.coordinator.editedText, "Review")
        XCTAssertEqual(returned.selectedRange(), originalSelection,
                       "Undo of the committed composition restores the pre-composition selection")
        XCTAssertEqual(fixture.coordinator.session.id, reviewID)
        XCTAssertTrue(undo.canRedo)
        undo.redo()
        XCTAssertEqual(returned.string, "Review composition")
        XCTAssertEqual(fixture.coordinator.editedText, "Review composition")
        XCTAssertEqual(returned.selectedRange(), committedSelection,
                       "Redo restores the committed composition selection")
        XCTAssertEqual(fixture.coordinator.session.id, reviewID)
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(NSApp.keyWindow === keyWindowBefore)
        XCTAssertTrue(fixture.clipboard.calls.isEmpty)
    }

    @MainActor private func verifySettingsRoundTrip(isAuxiliaryPanel: Bool) async throws {
        let selected = URL(fileURLWithPath: "/synthetic-review-never-opened.txt")
        let fixture = try CoordinatorFixture(configureEnvironment: { environment in
            environment.chooseTranscriptToOpen = { _ in selected }
            environment.readTranscript = { _ in "Review" }
        })
        fixture.coordinator.uiLanguage = .english
        fixture.coordinator.openTranscript(); await waitForOperation(fixture)
        let reviewID = fixture.coordinator.session.id
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: DictationView(coordinator: fixture.coordinator,
                                                        isAuxiliaryPanel: isAuxiliaryPanel)
            .transaction { $0.disablesAnimations = true; $0.animation = nil })
        window.contentView = host
        await refresh(host)
        let original = try XCTUnwrap(editor(in: host))
        XCTAssertTrue(window.makeFirstResponder(original))
        let originalSelection = (original.string as NSString).range(of: "Review")
        XCTAssertNotEqual(originalSelection.location, NSNotFound)
        original.setSelectedRange(originalSelection)
        let originalUndo = try XCTUnwrap(original.undoManager)
        originalUndo.beginUndoGrouping()
        original.insertText("Rewritten", replacementRange: originalSelection)
        originalUndo.endUndoGrouping()
        let editedSelection = original.selectedRange()
        XCTAssertTrue(originalUndo.canUndo, "Establish actual native Undo before navigation")
        XCTAssertEqual(fixture.coordinator.editedText, "Rewritten")

        try await select(1, in: host)
        XCTAssertFalse(original.isEditable)
        XCTAssertFalse(original.isSelectable)
        XCTAssertTrue(original.enclosingScrollView?.isHidden == true)
        XCTAssertFalse(window.firstResponder === original)
        XCTAssertEqual(fixture.coordinator.session.id, reviewID)
        XCTAssertEqual(fixture.coordinator.editedText, "Rewritten")
        XCTAssertEqual(original.selectedRange(), editedSelection,
                       "Settings must preserve the hidden editor selection")
        try await select(0, in: host)
        let returned = try XCTUnwrap(editor(in: host))
        XCTAssertTrue(returned === original, "Navigation must retain this same-review native editor")
        XCTAssertTrue(returned.isSelectable)
        XCTAssertFalse(try XCTUnwrap(returned.enclosingScrollView).isHidden)
        XCTAssertEqual(returned.string, "Rewritten")
        XCTAssertEqual(returned.selectedRange(), editedSelection,
                       "Returning to Dictation must restore the same review selection")
        XCTAssertEqual(fixture.coordinator.session.id, reviewID)
        let undo = try XCTUnwrap(returned.undoManager)
        XCTAssertTrue(undo.canUndo, "Settings is not a new review; it must not discard edit history")
        guard undo.canUndo else { return }
        undo.undo()
        XCTAssertEqual(returned.string, "Review")
        XCTAssertEqual(fixture.coordinator.editedText, "Review")
        XCTAssertEqual(returned.selectedRange(), originalSelection,
                       "Undo restores the pre-edit selection")
        XCTAssertTrue(undo.canRedo)
        undo.redo()
        XCTAssertEqual(returned.string, "Rewritten")
        XCTAssertEqual(fixture.coordinator.editedText, "Rewritten")
        XCTAssertEqual(returned.selectedRange(), editedSelection,
                       "Redo restores the post-edit selection")
        // A true replacement remains deliberately non-undoable across reviews.
        fixture.coordinator.discard()
        await refresh(host)
        XCTAssertFalse(undo.canUndo)
        XCTAssertFalse(undo.canRedo)
        fixture.coordinator.openTranscript(); await waitForOperation(fixture)
        await refresh(host)
        let replacement = try XCTUnwrap(editor(in: host))
        XCTAssertFalse(replacement === original)
        XCTAssertNotEqual(fixture.coordinator.session.id, reviewID)
        XCTAssertFalse(try XCTUnwrap(replacement.undoManager).canUndo)
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(fixture.clipboard.calls.isEmpty)
    }

}

@MainActor private final class FocusOriginReference {
    weak var button: NSButton?
}

private struct FocusOriginHandoffFixture: View {
    @State private var settingsVisible = false
    let origin: FocusOriginReference

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LocalizedNavigationSegments(settingsVisible: $settingsVisible,
                accessibilityTitle: "View", dictationTitle: "Dictation", settingsTitle: "Settings")
            FocusOriginButton(origin: origin, isHidden: settingsVisible)
        }
        .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
    }
}

private struct FocusOriginButton: NSViewRepresentable {
    let origin: FocusOriginReference
    let isHidden: Bool

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "Synthetic content action", target: nil, action: nil)
        button.frame = NSRect(x: 0, y: 0, width: 220, height: 28)
        origin.button = button
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        button.isHidden = isHidden
    }
}
