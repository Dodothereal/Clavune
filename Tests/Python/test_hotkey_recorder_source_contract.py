"""Portable source-bound guards; they do not establish AppKit/Carbon behavior."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
APP = (ROOT / "Sources/ClavuneApp/AppCoordinator.swift").read_text()
VIEW = (ROOT / "Sources/ClavuneApp/FocusedHotkeyRecorder.swift").read_text()
PRESENTATION = (ROOT / "Sources/ClavuneApp/Presentation.swift").read_text()
LANGUAGE = (ROOT / "Sources/ClavuneApp/UILanguage.swift").read_text()
SERVICE = (ROOT / "Sources/ClavuneApp/HotkeyService.swift").read_text()


class HotkeyRecorderSourceContracts(unittest.TestCase):
    def test_local_focused_key_up_precedes_registration(self):
        self.assertNotIn("addGlobalMonitorForEvents", VIEW)
        self.assertNotIn("addLocalMonitorForEvents", VIEW)
        self.assertNotIn("event.characters", VIEW)
        self.assertIn("override func keyUp(with event: NSEvent)", VIEW)
        self.assertIn("capture.keyUp(keyCode:", VIEW)
        self.assertIn("onChord?(chord.keyCode, chord.modifiers)", VIEW)
        key_up = VIEW.split("override func keyUp(with event: NSEvent)", 1)[1].split("override func draw", 1)[0]
        self.assertLess(key_up.index("onPendingChange?(capture.hasPending)"),
                        key_up.index("guard let chord else { return }"))
        down = VIEW.split("override func keyDown(with event: NSEvent)", 1)[1].split("override func keyUp", 1)[0]
        self.assertNotIn("onChord?", down)
        self.assertIn("guard !repeatEvent else { return }", VIEW)
        self.assertIn("private var heldKeys: Set<UInt32>", VIEW)
        self.assertIn("guard heldKeys.remove(keyCode) != nil else { return nil }", VIEW)
        self.assertIn("capture.clear()", VIEW)
        self.assertIn("let hadPending = capture.hasPending", VIEW)
        self.assertIn("onFocusLost?(hadPending)", VIEW)
        resign = VIEW.split("override func resignFirstResponder() -> Bool {", 1)[1].split("override func mouseDown", 1)[0]
        self.assertLess(resign.index("onFocusLost?(hadPending)"), resign.index("onPendingChange?(false)"))

    def test_privacy_and_navigation_close_recorder_without_rearming(self):
        self.assertIn("if hotkeyRecording { abortHotkeyRecordingForPrivacy(); return }", APP)
        abort = APP.split("private func abortHotkeyRecordingForPrivacy()", 1)[1].split("/// A rejected chord", 1)[0]
        for token in ["hotkeyGeneration &+= 1", "retired?.unregister()", "hotkeyEnabled = false"]:
            self.assertIn(token, abort)
        self.assertLess(abort.index("hotkeyEnabled = false"), abort.index("retired?.unregister()"))
        self.assertNotIn("configureHotkey()", abort)
        self.assertIn("if environment.secureInputEnabled() { abortHotkeyRecordingForPrivacy(); return false }", APP)
        self.assertIn("if !isVisible && ownsHotkeyRecording", PRESENTATION)
        self.assertIn("if hadPending { coordinator.interruptForPrivacy() }", PRESENTATION)
        self.assertIn("else { coordinator.cancelHotkeyRecording() }", PRESENTATION)
        self.assertIn("if hotkeyChordPending { abortHotkeyRecordingForPrivacy(); return }", APP)
        cancel = APP.split("func cancelHotkeyRecording() {", 1)[1].split("private func abortHotkeyRecordingForPrivacy", 1)[0]
        self.assertLess(cancel.index("if hotkeyChordPending"), cancel.index("configureHotkey()"))
        self.assertIn("onPendingChange: { coordinator.setHotkeyChordPending($0) }", PRESENTATION)
        self.assertNotIn("@State private var hotkeyChordPending", PRESENTATION)

    def test_choice_does_not_automatically_enable_and_all_statuses_are_localized(self):
        self.assertIn("if !restoreEnabled {", APP)
        self.assertIn("hotkeyEnabled = false", APP)
        self.assertIn("coordinator.beginHotkeyRecording()", PRESENTATION)
        self.assertNotIn("$coordinator.developmentShortcut", PRESENTATION)
        for source in [
            "Tastenkürzel aufnehmen …", "Tastenkürzelaufnahme abbrechen",
            "Tastenkürzel eingeben", "Aktuelles Tastenkürzel",
            "Datenschutz-Unterbrechung; Hotkey aus. Bei Bedarf bewusst erneut aktivieren.",
            "Sichere Eingabe ist aktiv; Tastenkürzelaufnahme nicht gestartet.",
        ]:
            self.assertIn('"' + source + '":', LANGUAGE)

    def test_carbon_handler_filters_event_identity(self):
        self.assertIn("GetEventParameter(event", SERVICE)
        self.assertIn("incoming.id == service.eventID.id", SERVICE)
        self.assertIn("incoming.signature == service.eventID.signature", SERVICE)

    def test_registration_action_is_not_live_until_registrar_returns(self):
        install = APP.split("private func installHotkey(_ shortcut: DevelopmentShortcut) -> HotkeyInstallResult {", 1)[1].split("private func receiveHotkeyEdge", 1)[0]
        self.assertLess(install.index("hotkeyRegistrationReady = false"),
                        install.index("environment.registerHotkey(shortcut)"))
        self.assertIn("self.hotkeyRegistrationReady", install)
        self.assertLess(install.index("let registration = try environment.registerHotkey"),
                        install.index("hotkeyRegistrationReady = true"))
        self.assertLess(install.index("guard generation == hotkeyGeneration, hotkeyEnabled,"),
                        install.index("hotkey = registration"))


if __name__ == "__main__":
    unittest.main()
