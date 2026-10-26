"""Portable source checks; not a substitute for native XCTest or visual QA."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "Sources/ClavuneApp"


class DictationRecoveryContracts(unittest.TestCase):
    def test_recovery_handles_every_error_and_localizes_all_guidance(self):
        policy = (ROOT / "Sources/ClavuneCore/Policy.swift").read_text()
        cases = policy.split("public enum DictationError:", 1)[1].split("public var errorDescription", 1)[0]
        declared = set(re.findall(r"\b\w+\b", " ".join(re.findall(r"case ([^\n]+)", cases))))
        recovery = (APP / "DictationRecovery.swift").read_text()
        guidance = recovery.split("var guidance: String {", 1)[1].split("var offersNewRecording:", 1)[0]
        self.assertEqual(declared, set(re.findall(r"\.(\w+)", " ".join(re.findall(r"case ([^:]+):", guidance)))))
        self.assertNotIn("default:", guidance)
        translations = set(re.findall(r'^        "([^"\n]+)":', (APP / "UILanguage.swift").read_text(), re.M))
        for source in [guidance, (APP / "DictationRecoveryView.swift").read_text()]:
            for key in re.findall(r'(?:return |ui.text\()"([^"\n]+)"', source):
                with self.subTest(key=key):
                    self.assertIn(key, translations)

    def test_retry_is_failed_only_and_uses_normal_admission_without_audio_replay(self):
        source = (APP / "DictationRecovery.swift").read_text()
        self.assertIn("guard session.phase == .failed, let error = session.failure else { return nil }", source)
        self.assertIn("dictationRecovery?.offersNewRecording == true && canStart && microphone.state == .closed", source)
        retry = source.split("func retryFailedRecording() {", 1)[1].split("}", 2)
        self.assertIn("guard canRetryFailedRecording else { return", retry[0])
        self.assertIn("start()", retry[1])
        self.assertNotRegex(source, r"(?:inference|capture|preferences)\.")
        self.assertNotIn("session.discard", source)
        coordinator = (APP / "AppCoordinator.swift").read_text()
        can_start = coordinator.split("var canStart: Bool {", 1)[1].split("\n    }", 1)[0]
        self.assertIn("!isPresentationQA && !busy && model != nil && !hasPendingReview", can_start)
        self.assertIn("!microphoneModelNeedsRevalidation", can_start)
        self.assertIn("microphoneModelNeedsRevalidation = true", coordinator)
        self.assertIn("resolveMicrophoneModelFailureAfterVerification()", coordinator)

    def test_failure_replaces_ready_placeholder_and_buttons_remain_explicit(self):
        presentation = (APP / "Presentation.swift").read_text()
        self.assertLess(presentation.index("case .recovery:"), presentation.index("case .ready:"))
        self.assertIn("if let recovery = coordinator.dictationRecovery", presentation)
        self.assertIn("openSettings: { settingsVisible = true }", presentation)
        view = (APP / "DictationRecoveryView.swift").read_text()
        self.assertIn("if recovery.offersNewRecording", view)
        self.assertIn("action: coordinator.retryFailedRecording", view)
        self.assertIn(".disabled(!coordinator.canRetryFailedRecording)", view)
        self.assertNotRegex(view, r"onAppear|\.task\s*\{|onChange")


if __name__ == "__main__":
    unittest.main()
