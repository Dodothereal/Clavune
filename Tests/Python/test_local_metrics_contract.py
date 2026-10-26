"""Portable source gates for local metrics; not a substitute for XCTest."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
CORE = ROOT / "Sources/ClavuneCore"
APP = ROOT / "Sources/ClavuneApp"


class LocalMetricsContracts(unittest.TestCase):
    def test_journal_quota_is_serialized_across_processes(self):
        source = (CORE / "LocalMetricsJournal.swift").read_text()
        self.assertIn('appendingPathComponent(".writer.lock"', source)
        self.assertIn("O_NOFOLLOW | O_CLOEXEC", source)
        self.assertIn("flock(candidate, LOCK_EX | LOCK_NB) == 0", source)
        self.assertIn("releaseWriterLock()", source)
        self.assertIn("totalBytes <= limits.totalBytes - bytes.count", source)

    def test_recovery_uses_the_same_semantic_validation_as_writes(self):
        source = (CORE / "LocalMetricsJournal.swift").read_text()
        recovery = source.split("for rawLine in data.split", 1)[1].split("if data.last != 0x0A", 1)[0]
        self.assertIn("static func isValid(_ event: LocalMetricsEvent)", source)
        self.assertIn("Self.isValid(event)", source.split("private func appendSynchronously", 1)[1]
                      .split("private func prepareIfNeeded", 1)[0])
        self.assertIn("Self.isValid(event)", recovery)
        self.assertLess(recovery.index("Self.isValid(event)"), recovery.index("eventIDs.insert"))
        self.assertLess(recovery.index("Self.isValid(event)"), recovery.index("terminalSessions.insert"))

    def test_metric_labels_distinguish_source_and_processing_rates(self):
        journal = (CORE / "LocalMetricsJournal.swift").read_text()
        coordinator = (APP / "AppCoordinator.swift").read_text()
        self.assertIn("sourceSampleRateHz", journal)
        self.assertIn("processingSampleRateHz", journal)
        imported = coordinator.split("func importAudio()", 1)[1].split("private func cancelAudioImport()", 1)[0]
        self.assertIn("metrics?.sourceSampleRate = nil", imported)
        self.assertIn("metrics?.processingSampleRate = 16_000", imported)
        self.assertIn("modelLoadSeconds == nil ? nil : value.modelWarm", coordinator)

    def test_revision_count_starts_after_initial_result_and_counts_reverts(self):
        coordinator = (APP / "AppCoordinator.swift").read_text()
        observer = coordinator.split("@Published var editedText", 1)[1].split("@Published var uiLanguage", 1)[0]
        self.assertIn("reviewRevisionSessionID == session.id", observer)
        self.assertNotIn("editedText != session.rawTranscript", observer)
        self.assertIn("reviewRevisionCount = 0; reviewRevisionSessionID = id", coordinator)

    def test_metrics_stay_content_free_and_off_in_synthetic_qa(self):
        coordinator = (APP / "AppCoordinator.swift").read_text()
        self.assertIn("launchConfiguration.isQA ? nil : LocalMetricsJournal.applicationDefault()", coordinator)
        event_builder = coordinator.split("private func recordSessionMetrics", 1)[1].split("private func recordReviewAction", 1)[0]
        self.assertNotRegex(event_builder, r"editedText|rawTranscript|clipboard.*contents|filePath")
        journal = (CORE / "LocalMetricsJournal.swift").read_text()
        self.assertIn('DictationError(rawValue: $0) != nil || $0 == "process_interrupted"', journal)
        self.assertIn("value.utf8.count == 64 && value.utf8.allSatisfy", journal)


if __name__ == "__main__":
    unittest.main()
