"""Source wiring checks only: these do not run AppKit or prove focus traversal."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'Sources/ClavuneCore/LocalClipboard.swift'
NATIVE = ROOT / 'Tests/ClavuneCoreTests/TranscriptKeyboardTests.swift'


class TranscriptKeyboardSourceContracts(unittest.TestCase):
    def test_tab_commands_delegate_only_to_native_key_loop_with_composition_fallback(self):
        source = SOURCE.read_text()
        for name, movement in [('insertTab', 'selectNextKeyView'),
                               ('insertBacktab', 'selectPreviousKeyView')]:
            with self.subTest(command=name):
                body = re.search(r'public override func ' + name + r'\(_ sender: Any\?\) \{(.*?)\n    \}',
                                 source, re.S).group(1)
                self.assertIn('guard !hasMarkedText(), let window else', body)
                self.assertIn('super.' + name + '(sender); return', body)
                self.assertIn('window.' + movement + '(self)', body)
                self.assertNotRegex(body, r'insertText|delete\(|copy\(|cut\(|pasteboard|setSelected|\.string\s*=')

    def test_literal_tab_multiline_and_native_editing_are_not_overridden(self):
        source = SOURCE.read_text()
        for method in ['insertTabIgnoringFieldEditor', 'insertNewline', 'keyDown', 'undo', 'redo']:
            self.assertNotRegex(source, r'override func\s+' + method + r'\b')
        self.assertNotIn('isFieldEditor =', source)
        self.assertNotIn('addLocalMonitorForEvents', source)
        self.assertNotIn('addGlobalMonitorForEvents', source)

    def test_both_production_transcript_hosts_retain_plain_text_view(self):
        presentation = (ROOT / 'Sources/ClavuneApp/Presentation.swift').read_text()
        self.assertIn('let editor = PlainTranscriptTextView(frame: .zero)', presentation)
        self.assertIn('TranscriptEditor(text: $coordinator.editedText, isPresented: !settingsVisible,', presentation)
        self.assertIn('TranscriptEditor(text: .constant(coordinator.session.rawTranscript), isEditable: false,', presentation)
        self.assertEqual(presentation.count('clipboardWriteSink: coordinator.qaTranscriptClipboardSink)'), 2)

    def test_native_cases_check_focus_and_text_and_do_not_use_clipboard_or_order_windows(self):
        native = NATIVE.read_text()
        for evidence in ['for editable in [true, false]', '0..<3',
                         'firstResponder === fixture.after', 'firstResponder === fixture.before',
                         'XCTAssertEqual(editor.string, original)', 'XCTAssertEqual(editor.selectedRange(), selection)',
                         'insertTabIgnoringFieldEditor', 'insertNewline', 'hasMarkedText()',
                         'textShouldEndEditing', 'XCTAssertNil(editor.window)']:
            self.assertIn(evidence, native)
        self.assertNotRegex(native, r'NSPasteboard\.|\.copy\(|\.cut\(|orderFront|makeKeyAndOrderFront|setActivationPolicy')
        self.assertIn('CLAVUNE_RUN_UI_HOST_FIXTURES', native)

    def test_native_editing_veto_observes_real_edit_and_both_delegate_attempts(self):
        native = NATIVE.read_text()
        veto = native.split('func testEditingVetoDoesNotInsertATabOrDestroyReview()', 1)[1].split(
            'func testUnattachedEditorRetainsNativeTabInsertion()', 1)[0]
        self.assertLess(veto.index('makeFirstResponder(editor)'), veto.index('editor.insertText("keep ",'))
        self.assertLess(veto.index('XCTAssertEqual(veto.editingBegins, 1)'), veto.index('NSResponder.insertTab('))
        self.assertIn('XCTAssertGreaterThan(veto.endAttempts, tabEndAttempts,', veto)
        self.assertIn('XCTAssertGreaterThan(veto.endAttempts, backtabEndAttempts,', veto)
        self.assertEqual(veto.count('XCTAssertTrue(fixture.window.firstResponder === editor)'), 3)
        self.assertEqual(veto.count('XCTAssertEqual(editor.selectedRange(), selection)'), 2)


if __name__ == '__main__':
    unittest.main()
