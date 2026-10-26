"""Supplemental source contracts only; NOT execution of Swift cancellation or XCTest."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
RESET = "if session.phase == .cancelled { session.discard() }"


class ModelRetryContracts(unittest.TestCase):
    def setUp(self):
        self.app = (ROOT / "Sources/ClavuneApp/AppCoordinator.swift").read_text()
        self.native = (ROOT / "Tests/ClavuneCoreTests/ModelOperationRetryTests.swift").read_text()

    def test_import_reset_follows_the_complete_picker_admission_guard(self):
        body = self.app.split("    func importModel() {", 1)[1].split("    func downloadModel(", 1)[0]
        self.assertEqual(body.count(RESET), 1)
        before, after = body.split(RESET)
        self.assertIn("guard !isPresentationQA, !busy, let admission = importAdmission.begin()", before)
        self.assertIn("guard let selected = environment.chooseModel(),", before)
        self.assertIn("importAdmission.permits(admission), generation == cancellationGeneration,", before)
        self.assertIn("!closePending, !session.phase.isBusy else {", before)
        self.assertIn("importAdmission.finish(admission); modelOperationPending = false", before)
        self.assertIn("resumeDeferredQuitSaveIfReady()\n            return\n        }", before)
        self.assertNotIn("operationPending = true", before)
        self.assertIn("operationPending = true; operationNeedsDrain = true", after)
        self.assertEqual(body.count("session.discard()"), 1)

    def test_download_reset_follows_candidate_match_and_admission(self):
        body = self.app.split("    func downloadModel(", 1)[1].split("    /// Deliberate read-only local hash check.", 1)[0]
        self.assertEqual(body.count(RESET), 1)
        before, after = body.split(RESET)
        self.assertIn("guard !isPresentationQA, !busy, candidate.downloadEnabled,", before)
        for field in ["sha256", "fileName", "sizeBytes", "license", "role", "sourceURL", "sourceRevision", "downloadEnabled"]:
            self.assertIn(f"$0.{field} == candidate.{field}", before)
        self.assertIn("let admission = importAdmission.begin() else { return }", before)
        self.assertNotIn("modelOperationPending = true", before)
        self.assertIn("modelOperationPending = true", after)
        self.assertEqual(body.count("session.discard()"), 1)

    def test_finish_still_reports_current_cancellation_and_existing_reset_precedents_remain(self):
        body = self.app.split("    private func finishOperation(preservingMessage: Bool = false) {", 1)[1]
        body = body.split("    private func resolveMicrophoneModelFailureAfterVerification()", 1)[0]
        self.assertIn("if !preservingMessage, session.phase == .cancelled, !closePending {", body)
        self.assertIn('message = "Abgebrochen. Mikrofon geschlossen."', body)
        self.assertEqual(self.app.count(RESET), 5)

    def test_unload_preserves_only_success_message_without_mutating_session(self):
        body = self.app.split("    func unload() {", 1)[1].split("    /// UI commands", 1)[0]
        self.assertIn("guard !busy else { return }", body)
        self.assertIn("operationPending = true; operationNeedsDrain = true; modelOperationPending = true", body)
        self.assertIn("defer { modelOperationPending = false; finishOperation(preservingMessage: !Task.isCancelled) }", body)
        self.assertIn("await inference.unload()", body)
        self.assertIn("guard !Task.isCancelled else { return }", body)
        self.assertNotIn("session.discard()", body)

    def test_native_fixtures_assert_results_noops_review_and_new_cancellation(self):
        for name in ["testImportSuccessAfterCancellationKeepsFreshResult",
                     "testImportFailureAfterCancellationKeepsRecoveryGuidance",
                     "testDownloadSuccessAfterCancellationKeepsFreshResult",
                     "testDownloadFailureAfterCancellationKeepsStorageGuidance",
                     "testCancelledPickerDoesNotErasePreviousCancellation",
                     "testRejectedDownloadCandidateDoesNotErasePreviousCancellation",
                     "testCancellingFreshImportRetryStillWins",
                     "testCancellingFreshDownloadRetryStillWins",
                     "testNewModelActionsDoNotDiscardPendingReview"]:
            self.assertIn(name, self.native)
        self.assertIn("ModelStore.RecoveryError.backupAlreadyExists.localizedDescription", self.native)
        self.assertIn("downloadFailureMessage(for: ModelDownloadFailure.insufficientStorage)", self.native)
        self.assertIn("await fulfillment(of: [firstFinished, firstClosed]", self.native)
        self.assertIn("XCTAssertEqual(fixture.coordinator.session.phase, .idle", self.native)
        self.assertIn("fixture.chooseModel = { nil }", self.native)
        self.assertIn("sizeBytes: requested.sizeBytes - 1", self.native)
        self.assertIn("XCTAssertEqual(fixture.inference.counts.value.loads, 0)", self.native)
        self.assertIn("XCTAssertEqual(fixture.resources.counts.value.opened, 0)", self.native)
        self.assertNotRegex(self.native, r"URLSession|NSOpenPanel|NSPasteboard|NSApp|UserDefaults\.standard|Task\.sleep|Thread\.sleep")


if __name__ == "__main__":
    unittest.main()
