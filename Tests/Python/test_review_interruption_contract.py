"""Portable source contracts only; AppKit behavior needs the native fixture suite."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / 'Sources/ClavuneApp/AppCoordinator.swift').read_text()


def body(signature):
    start = SOURCE.index(signature) + len(signature)
    depth = 1
    end = start
    while depth:
        depth += (SOURCE[end] == '{') - (SOURCE[end] == '}')
        end += 1
    return SOURCE[start:end - 1]


class ReviewInterruptionContracts(unittest.TestCase):
    def test_automatic_routes_use_review_preserving_interruption(self):
        observer = SOURCE.split('if let center = environment.workspaceNotifications', 1)[1].split('var busy:', 1)[0]
        self.assertIn('NSWorkspace.willSleepNotification', observer)
        self.assertIn('NSWorkspace.sessionDidResignActiveNotification', observer)
        self.assertIn('self?.interruptForPrivacy()', observer)
        hotkey = body('    private func receiveHotkeyEdge(_ down: Bool) {')
        self.assertIn('if environment.secureInputEnabled() {', hotkey)
        self.assertIn('interruptForPrivacy(); return', hotkey)
        watchdog = body('    private func startPrivacyWatchdog() {')
        self.assertIn('self.interruptForPrivacy()', watchdog)

    def test_idle_closed_review_is_noop_but_busy_work_still_drains(self):
        interruption = body('    func interruptForPrivacy() {')
        self.assertIn('guard busy || microphone.state != .closed else { return }', interruption)
        self.assertIn('cancel(preservingReview: true)', interruption)
        self.assertNotIn('guard !hasPendingReview', interruption)

    def test_automatic_cancel_keeps_review_but_not_resource_work(self):
        cancellation = body('    private func cancel(preservingReview: Bool) {')
        self.assertIn('let keepReview = preservingReview && hasPendingReview', cancellation)
        protected = cancellation.split('if !keepReview {', 1)[1].split('}', 1)[0]
        self.assertIn('session.cancel(); editedText = ""', protected)
        for operation in ['startupGate?.invalidate(); importAdmission.invalidate()',
                          'cancellation?.cancel(); task?.cancel()',
                          'await capture.cancel(session: id)',
                          'microphone.acknowledgeClosed(id)', 'closePending = false']:
            self.assertIn(operation, cancellation)
            self.assertNotIn(operation, protected)

    def test_explicit_discard_model_cancel_and_dirty_quit_have_separate_policies(self):
        explicit = body('    func cancel() {')
        self.assertIn('if modelOperationPending, hasPendingReview { cancelModelOperationPreservingReview(); return }', explicit)
        self.assertIn('cancel(preservingReview: false)', explicit)
        self.assertLess(explicit.index('cancelModelOperationPreservingReview()'),
                        explicit.index('cancel(preservingReview: false)'))
        preserving = body('    private func cancelModelOperationPreservingReview() {')
        self.assertIn('importAdmission.invalidate()', preserving)
        self.assertIn('task?.cancel()', preserving)
        self.assertNotIn('session.cancel()', preserving)
        self.assertNotIn('editedText =', preserving)
        self.assertNotIn('capture.cancel', preserving)
        discard = body('    func discard() {')
        self.assertIn('guard !busy else { return }', discard)
        self.assertIn('session.discard(); editedText = ""; metrics = nil', discard)
        quit_request = body('    func quit() {')
        self.assertIn('guard !quitRequested, !quitDecisionPending, quitAttempt == nil else { return }', quit_request)
        self.assertIn('guard hasUnsavedReview else { beginQuit(); return }', quit_request)
        self.assertLess(quit_request.index('quitAttempt = attempt'), quit_request.index('quitDecisionPending = true'))
        self.assertIn('environment.confirmUnsavedReviewQuit(uiLanguage)', quit_request)
        self.assertIn('case .cancel: finishQuitDecision(attempt)', quit_request)
        self.assertIn('case .discard:', quit_request)
        self.assertIn('case .save:', quit_request)
        self.assertIn('await pendingOperation.value', quit_request)
        self.assertIn('saveTranscript(forQuit: attempt)', quit_request)
        self.assertNotIn('session.cancel()', quit_request)
        shutdown = body('    private func beginQuit(preservingReview: Bool = false) {')
        self.assertIn('cancel(preservingReview: preservingReview)', shutdown)
        self.assertIn('hotkeyRegistrationReady = false', shutdown)
        self.assertIn('retired?.unregister()', shutdown)
        self.assertLess(shutdown.index('hotkeyRegistrationReady = false'),
                        shutdown.index('retired?.unregister()'))
        self.assertLess(shutdown.index('await pendingOperation?.value'), shutdown.index('await inference.unload()'))


if __name__ == '__main__':
    unittest.main()
