import AppKit
import XCTest
@testable import ClavuneCore

/// Opt-in AppKit key-loop fixtures. Windows are never ordered onscreen or made
/// key; no global shortcut, clipboard, permission or system setting is accessed.
/// Direct native command dispatch is not a physical-key or VoiceOver acceptance test.
final class TranscriptKeyboardTests: XCTestCase {
    @MainActor private final class FocusTarget: NSView {
        override var acceptsFirstResponder: Bool { true }
        override var canBecomeKeyView: Bool { true }
    }

    @MainActor private final class EditingVeto: NSObject, NSTextViewDelegate {
        var editingBegins = 0
        var endAttempts = 0
        func textDidBeginEditing(_ notification: Notification) { editingBegins += 1 }
        func textShouldEndEditing(_ textObject: NSText) -> Bool {
            endAttempts += 1
            return false
        }
    }

    @MainActor private struct Fixture {
        let window: NSWindow
        let editor: PlainTranscriptTextView
        let before: FocusTarget
        let after: FocusTarget

        init(editable: Bool = true) {
            _ = NSApplication.shared
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.autorecalculatesKeyViewLoop = false
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 240))
            window.contentView = content
            before = FocusTarget(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
            after = FocusTarget(frame: NSRect(x: 0, y: 220, width: 20, height: 20))
            editor = PlainTranscriptTextView(frame: NSRect(x: 0, y: 20, width: 360, height: 200))
            editor.isRichText = false
            editor.isEditable = editable
            editor.isSelectable = true
            editor.allowsUndo = editable
            content.addSubview(before); content.addSubview(editor); content.addSubview(after)
            before.nextKeyView = editor; editor.nextKeyView = after; after.nextKeyView = before
            window.initialFirstResponder = editor
        }
    }

    private func requireUIHostFixtures() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CLAVUNE_RUN_UI_HOST_FIXTURES"] == "1",
                          "Run only in the authorized macOS in-memory UI-host fixture pass")
    }

    @MainActor func testTabAndBacktabRepeatedlyTraverseEditableAndReadonlyReviewWithoutMutation() throws {
        try requireUIHostFixtures()
        for editable in [true, false] {
            let fixture = Fixture(editable: editable)
            defer { fixture.window.close() }
            let editor = fixture.editor
            let original = "Review \u{1F469}\u{200D}\u{1F4BB} e\u{301}\nsecond line"
            editor.string = original
            let selection = (original as NSString).range(of: "\u{1F469}\u{200D}\u{1F4BB} e\u{301}")
            editor.setSelectedRange(selection)
            XCTAssertTrue(editor.nextValidKeyView === fixture.after)
            XCTAssertTrue(editor.previousValidKeyView === fixture.before)
            for _ in 0..<3 {
                XCTAssertTrue(fixture.window.makeFirstResponder(editor))
                editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
                XCTAssertTrue(fixture.window.firstResponder === fixture.after)
                XCTAssertEqual(editor.string, original)
                XCTAssertEqual(editor.selectedRange(), selection)
                XCTAssertTrue(fixture.window.makeFirstResponder(editor))
                editor.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
                XCTAssertTrue(fixture.window.firstResponder === fixture.before)
                XCTAssertEqual(editor.string, original)
                XCTAssertEqual(editor.selectedRange(), selection)
            }
            XCTAssertFalse(fixture.window.isVisible)
        }
    }

    @MainActor func testExplicitLiteralTabAndReturnRemainNativeEditableCommands() throws {
        try requireUIHostFixtures()
        let fixture = Fixture()
        defer { fixture.window.close() }
        let editor = fixture.editor
        editor.string = "A selected Z"
        editor.setSelectedRange((editor.string as NSString).range(of: "selected"))
        XCTAssertTrue(fixture.window.makeFirstResponder(editor))
        editor.doCommand(by: #selector(NSResponder.insertTabIgnoringFieldEditor(_:)))
        XCTAssertEqual(editor.string, "A \t Z")
        XCTAssertTrue(fixture.window.firstResponder === editor)
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(editor.string, "A \t\n Z")
        XCTAssertTrue(fixture.window.firstResponder === editor)
    }

    @MainActor func testMarkedTextKeepsNativeCompositionFocusForBothTabCommands() throws {
        try requireUIHostFixtures()
        let fixture = Fixture()
        defer { fixture.window.close() }
        let editor = fixture.editor
        for command in [#selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:))] {
            editor.string = ""
            XCTAssertTrue(fixture.window.makeFirstResponder(editor))
            editor.setMarkedText("composition", selectedRange: NSRange(location: 11, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertTrue(editor.hasMarkedText())
            editor.doCommand(by: command)
            XCTAssertTrue(fixture.window.firstResponder === editor)
            editor.unmarkText()
        }
    }

    @MainActor func testEditingVetoDoesNotInsertATabOrDestroyReview() throws {
        try requireUIHostFixtures()
        let fixture = Fixture()
        defer { fixture.window.close() }
        let editor = fixture.editor
        let veto = EditingVeto()
        editor.delegate = veto
        editor.string = "review"
        XCTAssertTrue(fixture.window.makeFirstResponder(editor))
        // Setting .string alone does not establish an active native edit.
        // Exercise and observe the real editing lifecycle before testing its veto.
        editor.insertText("keep ", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(veto.editingBegins, 1)
        XCTAssertEqual(editor.string, "keep review")
        let selection = NSRange(location: 0, length: 4)
        editor.setSelectedRange(selection)
        XCTAssertTrue(fixture.window.firstResponder === editor)
        let tabEndAttempts = veto.endAttempts
        editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
        XCTAssertGreaterThan(veto.endAttempts, tabEndAttempts, "Tab must reach the native editing veto")
        XCTAssertTrue(fixture.window.firstResponder === editor)
        XCTAssertEqual(editor.string, "keep review")
        XCTAssertEqual(editor.selectedRange(), selection)
        let backtabEndAttempts = veto.endAttempts
        editor.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
        XCTAssertGreaterThan(veto.endAttempts, backtabEndAttempts, "Backtab must independently reach the veto")
        XCTAssertTrue(fixture.window.firstResponder === editor)
        XCTAssertEqual(editor.string, "keep review")
        XCTAssertEqual(editor.selectedRange(), selection)
        editor.delegate = nil
    }

    @MainActor func testUnattachedEditorRetainsNativeTabInsertion() {
        let editor = PlainTranscriptTextView(frame: .zero)
        editor.isRichText = false; editor.isEditable = true
        editor.string = "AZ"; editor.setSelectedRange(NSRange(location: 1, length: 0))
        XCTAssertNil(editor.window)
        editor.insertTab(nil)
        XCTAssertEqual(editor.string, "A\tZ")
    }
}
