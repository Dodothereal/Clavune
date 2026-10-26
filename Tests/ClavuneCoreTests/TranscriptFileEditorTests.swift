import AppKit
import SwiftUI
import XCTest
@testable import ClavuneApp
@testable import ClavuneCore

/// Opt-in in-memory native host, never visible; no clipboard, real panels, or files.
final class TranscriptFileEditorTests: UIFixtureAssertions {
    @MainActor private func editableReview(in view: NSView) -> PlainTranscriptTextView? {
        if let editor = view as? PlainTranscriptTextView, editor.isEditable { return editor }
        for child in view.subviews {
            if let editor = editableReview(in: child) { return editor }
        }
        return nil
    }

    @MainActor private func refresh(_ host: NSView) async {
        host.layoutSubtreeIfNeeded()
        let update = expectation(description: "native host update turn")
        DispatchQueue.main.async { update.fulfill() }
        await fulfillment(of: [update], timeout: 2)
        host.layoutSubtreeIfNeeded()
    }

    @MainActor func testSaveKeepsNativeUndoAndOpenStartsSeparateReviewUndoHistory() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CLAVUNE_RUN_UI_HOST_FIXTURES"] == "1",
                          "Run only in the authorized macOS in-memory UI-host fixture pass")
        _ = NSApplication.shared
        let selected = URL(fileURLWithPath: "/synthetic-transcript-never-opened.txt")
        let saved = FixtureValue<[String]>([])
        let fixture = try CoordinatorFixture(configureEnvironment: { environment in
            environment.chooseTranscriptToOpen = { _ in selected }
            environment.chooseTranscriptToSave = { _ in selected }
            environment.readTranscript = { _ in "opened file" }
            environment.writeTranscript = { text, _ in saved.update { $0.append(text) } }
            environment.confirmTranscriptReplacement = { _ in true }
        })
        fixture.coordinator.openTranscript(); await waitForOperation(fixture)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: DictationView(coordinator: fixture.coordinator))
        window.contentView = host
        await refresh(host)
        let editor = try XCTUnwrap(editableReview(in: host))
        XCTAssertTrue(window.makeFirstResponder(editor))
        let undo = try XCTUnwrap(editor.undoManager)
        undo.beginUndoGrouping()
        editor.insertText(" edited", replacementRange: NSRange(location: (editor.string as NSString).length, length: 0))
        undo.endUndoGrouping()
        XCTAssertEqual(fixture.coordinator.editedText, "opened file edited")
        XCTAssertTrue(undo.canUndo, "Fixture must establish actual native Undo before Save")
        fixture.coordinator.saveTranscript(); await waitForOperation(fixture); await refresh(host)
        XCTAssertTrue(try XCTUnwrap(editableReview(in: host)) === editor)
        XCTAssertTrue(editor.undoManager === undo)
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        XCTAssertEqual(editor.string, "opened file")
        XCTAssertEqual(fixture.coordinator.editedText, "opened file")
        // Save reads the coordinator synchronously: it must see the just-undone text.
        fixture.coordinator.saveTranscript(); await waitForOperation(fixture); await refresh(host)
        XCTAssertEqual(saved.value, ["opened file edited", "opened file"])
        XCTAssertTrue(undo.canRedo)
        undo.redo()
        XCTAssertEqual(editor.string, "opened file edited")
        XCTAssertEqual(fixture.coordinator.editedText, "opened file edited")
        fixture.coordinator.openTranscript(); await waitForOperation(fixture); await refresh(host)
        let replacement = try XCTUnwrap(editableReview(in: host))
        XCTAssertFalse(replacement === editor)
        XCTAssertFalse(replacement.undoManager === undo)
        XCTAssertFalse(undo.canUndo, "Dismantling the old editor clears only its local history")
        XCTAssertFalse(undo.canRedo)
        XCTAssertFalse(try XCTUnwrap(replacement.undoManager).canUndo)
        XCTAssertEqual(replacement.string, "opened file")
        XCTAssertEqual(fixture.coordinator.editedText, "opened file")
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(fixture.clipboard.calls.isEmpty)
    }

    @MainActor func testAnotherHostDraftUpdateClearsOnlyStaleLocalUndoHistory() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CLAVUNE_RUN_UI_HOST_FIXTURES"] == "1",
                          "Run only in the authorized macOS in-memory UI-host fixture pass")
        _ = NSApplication.shared
        let selected = URL(fileURLWithPath: "/synthetic-transcript-never-opened.txt")
        let fixture = try CoordinatorFixture(configureEnvironment: { environment in
            environment.chooseTranscriptToOpen = { _ in selected }
            environment.readTranscript = { _ in "shared" }
        })
        fixture.coordinator.openTranscript(); await waitForOperation(fixture)
        let main = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 900),
                            styleMask: [.titled], backing: .buffered, defer: true)
        let panel = NSWindow(contentRect: main.frame, styleMask: [.titled], backing: .buffered, defer: true)
        main.isReleasedWhenClosed = false; panel.isReleasedWhenClosed = false
        defer { main.close(); panel.close() }
        let mainHost = NSHostingView(rootView: DictationView(coordinator: fixture.coordinator))
        let panelHost = NSHostingView(rootView: DictationView(coordinator: fixture.coordinator, isAuxiliaryPanel: true))
        main.contentView = mainHost; panel.contentView = panelHost
        await refresh(mainHost); await refresh(panelHost)
        let mainEditor = try XCTUnwrap(editableReview(in: mainHost))
        let panelEditor = try XCTUnwrap(editableReview(in: panelHost))
        let mainUndo = try XCTUnwrap(mainEditor.undoManager), panelUndo = try XCTUnwrap(panelEditor.undoManager)
        XCTAssertFalse(mainUndo === panelUndo)
        XCTAssertTrue(panel.makeFirstResponder(panelEditor))
        panelUndo.beginUndoGrouping()
        panelEditor.insertText(" panel", replacementRange: NSRange(location: 6, length: 0))
        panelUndo.endUndoGrouping()
        XCTAssertTrue(panelUndo.canUndo)
        await refresh(mainHost); await refresh(panelHost)
        XCTAssertEqual(mainEditor.string, "shared panel")
        XCTAssertTrue(panelUndo.canUndo, "The originating editor's binding echo must preserve its Undo")
        XCTAssertTrue(main.makeFirstResponder(mainEditor))
        mainUndo.beginUndoGrouping()
        mainEditor.insertText(" main", replacementRange: NSRange(location: 12, length: 0))
        mainUndo.endUndoGrouping()
        XCTAssertTrue(mainUndo.canUndo)
        await refresh(mainHost); await refresh(panelHost)
        XCTAssertEqual(panelEditor.string, "shared panel main")
        XCTAssertFalse(panelUndo.canUndo, "An external draft replacement invalidates old local undo ranges")
        XCTAssertTrue(mainUndo.canUndo)
        mainUndo.undo()
        XCTAssertEqual(mainEditor.string, "shared panel")
        XCTAssertEqual(fixture.coordinator.editedText, "shared panel")
        await refresh(mainHost); await refresh(panelHost)
        XCTAssertEqual(panelEditor.string, "shared panel")
        XCTAssertFalse(panelUndo.canUndo)
        XCTAssertTrue(mainUndo.canRedo)
        mainUndo.redo()
        XCTAssertEqual(mainEditor.string, "shared panel main")
        XCTAssertEqual(fixture.coordinator.editedText, "shared panel main")
        XCTAssertFalse(main.isVisible); XCTAssertFalse(panel.isVisible)
        XCTAssertTrue(fixture.clipboard.calls.isEmpty)
    }

    @MainActor func testLoadedReviewSupportsNativeUndoAndRedo() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CLAVUNE_RUN_UI_HOST_FIXTURES"] == "1",
                          "Run only in the authorized macOS in-memory UI-host fixture pass")
        _ = NSApplication.shared
        let loadedText = "Geladener Text Grüße 👋🏽\nZweite Zeile."
        let fixture = try CoordinatorFixture(configureEnvironment: { environment in
            environment.chooseTranscriptToOpen = { _ in
                URL(fileURLWithPath: "/synthetic-loaded-review-never-opened.txt")
            }
            environment.readTranscript = { _ in loadedText }
        })
        fixture.coordinator.openTranscript()
        await waitForOperation(fixture)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: DictationView(coordinator: fixture.coordinator))
        window.contentView = host
        await refresh(host)

        let editor = try XCTUnwrap(editableReview(in: host))
        XCTAssertEqual(editor.string, loadedText)
        XCTAssertTrue(window.makeFirstResponder(editor))
        let undo = try XCTUnwrap(editor.undoManager)
        let editedText = loadedText + " Bearbeitet."
        undo.beginUndoGrouping()
        editor.insertText(" Bearbeitet.", replacementRange: NSRange(location: (editor.string as NSString).length, length: 0))
        undo.endUndoGrouping()

        XCTAssertEqual(editor.string, editedText)
        XCTAssertEqual(fixture.coordinator.editedText, editedText)
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        XCTAssertEqual(editor.string, loadedText)
        XCTAssertEqual(fixture.coordinator.editedText, loadedText)
        XCTAssertTrue(undo.canRedo)
        undo.redo()
        XCTAssertEqual(editor.string, editedText)
        XCTAssertEqual(fixture.coordinator.editedText, editedText)
        XCTAssertTrue(fixture.clipboard.calls.isEmpty)
    }

    @MainActor func testCanonicalEquivalentEditSyncsExactBytesAndUndoRedoUTF16Selection() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CLAVUNE_RUN_UI_HOST_FIXTURES"] == "1",
                          "Run only in the authorized macOS in-memory UI-host fixture pass")
        _ = NSApplication.shared
        let selected = URL(fileURLWithPath: "/synthetic-normalization-review-never-opened.txt")
        let composed = "\u{00E9}", decomposed = "e\u{0301}"
        let saved = FixtureValue<Data?>(nil)
        let fixture = try CoordinatorFixture(configureEnvironment: { environment in
            environment.chooseTranscriptToOpen = { _ in selected }
            environment.chooseTranscriptToSave = { _ in selected }
            environment.readTranscript = { _ in composed }
            environment.writeTranscript = { text, _ in saved.value = Data(text.utf8) }
        })
        fixture.coordinator.openTranscript()
        await waitForOperation(fixture)
        XCTAssertFalse(fixture.coordinator.hasUnsavedReview)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: DictationView(coordinator: fixture.coordinator))
        window.contentView = host
        await refresh(host)

        let editor = try XCTUnwrap(editableReview(in: host))
        XCTAssertTrue(window.makeFirstResponder(editor))
        let undo = try XCTUnwrap(editor.undoManager)
        let originalSelection = NSRange(location: 0, length: 1)
        editor.setSelectedRange(originalSelection)
        undo.beginUndoGrouping()
        editor.insertText(decomposed, replacementRange: originalSelection)
        undo.endUndoGrouping()

        XCTAssertEqual(Data(editor.string.utf8), Data(decomposed.utf8))
        XCTAssertEqual(Data(fixture.coordinator.editedText.utf8), Data(decomposed.utf8))
        XCTAssertTrue(fixture.coordinator.hasUnsavedReview)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 2, length: 0),
                       "The decomposed replacement occupies two UTF-16 code units")
        XCTAssertTrue(undo.canUndo)

        undo.undo()
        XCTAssertEqual(Data(editor.string.utf8), Data(composed.utf8))
        XCTAssertEqual(Data(fixture.coordinator.editedText.utf8), Data(composed.utf8))
        XCTAssertEqual(editor.selectedRange(), originalSelection)
        XCTAssertFalse(fixture.coordinator.hasUnsavedReview)
        XCTAssertTrue(undo.canRedo)

        undo.redo()
        XCTAssertEqual(Data(editor.string.utf8), Data(decomposed.utf8))
        XCTAssertEqual(Data(fixture.coordinator.editedText.utf8), Data(decomposed.utf8))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 2, length: 0))
        XCTAssertTrue(fixture.coordinator.hasUnsavedReview)

        fixture.coordinator.saveTranscript()
        await waitForOperation(fixture)
        XCTAssertEqual(saved.value, Data(decomposed.utf8))
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(fixture.clipboard.calls.isEmpty)
    }

}
