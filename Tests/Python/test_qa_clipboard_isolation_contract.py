"""Static QA-boundary checks; never accesses a macOS pasteboard or UI host."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "Sources/ClavuneApp"


class QAClipboardIsolationContracts(unittest.TestCase):
    def test_qa_editor_blocks_native_pasteboard_reads_before_appkit(self):
        core = (ROOT / "Sources/ClavuneCore/LocalClipboard.swift").read_text()
        editor = core.split("public final class PlainTranscriptTextView:", 1)[1]
        self.assertIn("public var allowsSystemPasteboardRead: Bool { clipboardWriteSink == nil }", editor)
        for method in ("paste(_ sender:", "pasteAsPlainText(_ sender:",
                       "pasteAsRichText(_ sender:", "pasteFont(_ sender:",
                       "pasteRuler(_ sender:"):
            body = editor.split("public override func " + method, 1)[1].split("\n    }", 1)[0]
            self.assertLess(body.index("guard allowsSystemPasteboardRead else { return }"),
                            body.index("super."))
        for method in ("readSelection(from pasteboard: NSPasteboard) -> Bool",
                       "readSelection(from pasteboard: NSPasteboard,\n                                       type: NSPasteboard.PasteboardType) -> Bool"):
            body = editor.split("public override func " + method, 1)[1].split("\n    }", 1)[0]
            self.assertLess(body.index("guard allowsSystemPasteboardRead else { return false }"),
                            body.index("super.readSelection"))
        for method in ("draggingEntered(_ sender:", "draggingUpdated(_ sender:",
                       "prepareForDragOperation(_ sender:", "performDragOperation(_ sender:"):
            body = editor.split("public override func " + method, 1)[1].split("\n    }", 1)[0]
            self.assertLess(body.index("guard allowsSystemPasteboardRead else"), body.index("super."))
        self.assertIn("allowsSystemPasteboardRead ? super.readablePasteboardTypes : []", editor)
        self.assertIn("allowsSystemPasteboardRead ? super.acceptableDragTypes : []", editor)
        requestor = editor.split("public override func validRequestor(", 1)[1].split("\n    }", 1)[0]
        self.assertLess(requestor.index("guard allowsSystemPasteboardRead else { return nil }"),
                        requestor.index("super.validRequestor"))
        self.assertIn("XCTAssertFalse(editor.allowsSystemPasteboardRead)",
                      (ROOT / "Tests/ClavuneCoreTests/QAClipboardIsolationTests.swift").read_text())

    def test_qa_uses_injected_boundary_and_production_keeps_native_copy(self):
        source = (APP / "AppCoordinator.swift").read_text()
        sink = source.split("struct QATranscriptClipboardSink:", 1)[1].split("@MainActor\nfinal class", 1)[0]
        self.assertIn("return write(text)", sink)
        self.assertNotIn("NSPasteboard.general", sink.split("func prepareForNewContents", 1)[1])
        selected = source.split("var qaTranscriptClipboardSink:", 1)[1].split("@Published var language", 1)[0]
        self.assertIn("guard launchConfiguration.isQA else { return nil }", selected)
        self.assertIn("launchConfiguration.isFunctionalQA", selected)
        self.assertIn("environment.copyText", selected)
        self.assertIn("{ _ in false }", selected)
        functional = (APP / "FunctionalQAContext.swift").read_text()
        self.assertIn("copiedText = text; return true", functional)

    def test_both_review_editors_receive_sink_on_mount_and_update(self):
        source = (APP / "Presentation.swift").read_text()
        self.assertEqual(source.count("clipboardWriteSink: coordinator.qaTranscriptClipboardSink)"), 2)
        editor = source.split("struct TranscriptEditor: NSViewRepresentable", 1)[1]
        self.assertIn("editor.clipboardWriteSink = clipboardWriteSink", editor.split("func updateNSView", 1)[0])
        self.assertIn("editor.clipboardWriteSink = clipboardWriteSink", editor.split("func updateNSView", 1)[1])
        self.assertIn("testMountedFunctionalQAEditorRoutesNativeSelectionCopyAndCutInMemory", (
            ROOT / "Tests/ClavuneCoreTests/QAClipboardIsolationTests.swift").read_text())

    def test_qa_disables_other_app_owned_text_selection_surfaces(self):
        presentation = (APP / "Presentation.swift").read_text()
        model_status = presentation.split('settingsHeading("Modell")', 1)[1].split('ModelImportGuidance(', 1)[0]
        self.assertIn("if !coordinator.launchConfiguration.isQA {", model_status)
        self.assertIn("Text(ui.text(coordinator.modelStatus)).font(.caption).textSelection(.enabled)", model_status)
        self.assertEqual(presentation.count("allowsTextSelection: !coordinator.launchConfiguration.isQA"), 2)
        self.assertIn("Kopieren bleibt im Arbeitsspeicher; keine Aufnahme oder Modellgewichte.", presentation)
        self.assertNotIn("Keine Aufnahme, Modellgewichte oder Systemzwischenablage.", presentation)
        ui = (APP / "UILanguage.swift").read_text()
        self.assertIn("Copy stays in memory; no recording or model weights.", ui)
        guidance = (APP / "ModelImportGuidance.swift").read_text()
        self.assertIn("if allowsTextSelection {", guidance)
        self.assertIn("Text(value).textSelection(.disabled)", guidance)
        self.assertIn("selectableText(candidate.fileName)", guidance)
        self.assertIn("selectableText(String(format: ui.text(\"Quelle: %@ · Revision %@\")", guidance)


if __name__ == "__main__":
    unittest.main()
