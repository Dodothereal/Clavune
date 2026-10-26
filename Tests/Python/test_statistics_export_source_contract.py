"""Portable source contracts for explicit aggregate export; no native UI runs here."""
import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
APP = ROOT / "Sources" / "ClavuneApp"


class StatisticsExportSourceContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.encoder = (APP / "LocalStatisticsJSONExport.swift").read_text()
        cls.controller = (APP / "LocalStatisticsExportController.swift").read_text()
        cls.page = (APP / "LocalStatisticsPageView.swift").read_text()
        cls.language = (APP / "UILanguage.swift").read_text()
        cls.loader = (APP / "LocalStatisticsDiskLoader.swift").read_text()
        cls.gate = (APP / "LocalStatisticsExportGate.swift").read_text()
        cls.coordinator = (APP / "AppCoordinator.swift").read_text()
        cls.environment = (APP / "CoordinatorEnvironment.swift").read_text()

    def test_export_is_explicit_and_qa_or_unavailable_is_ineligible(self):
        self.assertIn('Button(ui.text("Angezeigten Statistikbericht als JSON exportieren …"))', self.page)
        self.assertIn("guard !qaDisabled && !isSyntheticPreview else { return nil }", self.page)
        self.assertIn(".disabled(exportInput == nil || exportController.state.isBusy)", self.page)
        self.assertIn("case .notLoaded, .loading, .failed, .qaUnavailable: return nil", self.encoder)
        self.assertNotIn(".onAppear { await export", self.page)

    def test_projection_is_whitelisted_and_bounded(self):
        self.assertIn("private struct Document: Encodable", self.encoder)
        self.assertIn("guard bytes.count <= 64 * 1024", self.encoder)
        self.assertNotIn('return text + "\\n"', self.encoder)
        for forbidden in ("LocalMetricsEvent: Codable", "Report: Codable", "modelFileName",
                          "modelSHA256", "backendFingerprint", "rawWordCount", "sessionID",
                          "eventID", "NSPasteboard.general"):
            self.assertNotIn(forbidden, self.encoder)
        self.assertIn('values.encodeNil(forKey: .startInclusiveUnixSeconds)', self.encoder)
        self.assertIn('values.encodeNil(forKey: .value)', self.encoder)

    def test_reader_and_display_states_are_not_conflated(self):
        self.assertIn("displayState: input.displayState", self.encoder)
        self.assertIn("visiblePrefixReaderState: reader.rawValue", self.encoder)
        self.assertIn("(reader == .partial) == result.isPartial", self.encoder)
        self.assertIn("report.historicalCoverageUnknown", self.encoder)
        self.assertIn("(try? input.selection.interval", self.encoder)
        self.assertIn('"unreportedFiniteFilterSentinelNotCoverageStart"', self.encoder)
        self.assertIn("diagnostics.readerState = read.state", self.loader)

    def test_no_writer_before_chooser_or_after_chooser_cancellation(self):
        self.assertLess(self.controller.index("LocalStatisticsJSONExport.encode"),
                        self.controller.index("environment.chooseDestination"))
        self.assertLess(self.controller.index("environment.chooseDestination"),
                        self.controller.index("gate.startWriter"))
        self.assertIn("guard !Task.isCancelled else { state = .cancelledBeforeWrite; return }", self.controller)
        self.assertIn("gate.permitsWriting(admission)", self.controller)
        self.assertIn("Task.detached(priority: .utility)", self.gate)
        self.assertIn("TranscriptFileStore.write", self.controller)
        self.assertNotIn("recordReviewAction", self.controller)

    def test_process_gate_closes_synchronously_before_quit_drain(self):
        self.assertIn("static let shared = LocalStatisticsExportGate()", self.gate)
        self.assertIn("guard !closing, !quitSavePending, active == nil", self.gate)
        self.assertIn("guard permitsWriting(id)", self.gate)
        self.assertIn("quitSavePending = true", self.gate)
        self.assertIn("await withCheckedContinuation { idleWaiters.append($0) }", self.gate)
        self.assertIn("await environment.waitForStatisticsExportIdle()", self.coordinator)
        self.assertIn("!environment.statisticsExportActive()", self.coordinator)
        self.assertIn("closing = true", self.gate)
        self.assertIn("closeStatisticsExportsForQuit: { LocalStatisticsExportGate.shared.closeForQuit() }",
                      self.environment)
        begin = self.coordinator[self.coordinator.index("private func beginQuit("):]
        self.assertLess(begin.index("let pendingStatisticsExport = environment.closeStatisticsExportsForQuit()"),
                        begin.index("Task {"))
        self.assertLess(begin.index("pendingStatisticsExport.result"),
                        begin.index("terminationReady = true"))

    def test_all_export_user_copy_has_english_translation(self):
        keys = set(re.findall(r'ui\.text\("([^"\\]*(?:\\.[^"\\]*)*)"\)',
                              self.page + self.controller))
        missing = sorted(key for key in keys if key != "Deutsch" and f'"{key}":' not in self.language)
        self.assertEqual(missing, [])


if __name__ == "__main__":
    unittest.main()
