"""Portable source contracts, not execution of Swift, AppKit panels, or file I/O."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / 'Sources/ClavuneApp'
CORE = ROOT / 'Sources/ClavuneCore'


def method(source, signature):
    return source.split(signature, 1)[1].split('\n    func ', 1)[0]


class TranscriptFileSourceContracts(unittest.TestCase):
    def test_plain_text_limits_and_strict_decode_are_in_the_production_store(self):
        source = (CORE / 'TranscriptFileStore.swift').read_text()
        for requirement in ['maximumBytes = 4 * 1024 * 1024', 'url.isFileURL',
                            'O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC', 'fstat(descriptor, &info)',
                            'mode_t(S_IFREG)', 'min(64 * 1024, maximumBytes + 1 - data.count)',
                            'data.count <= maximumBytes', 'String(data: data, encoding: .utf8)',
                            'text.utf8.count <= maximumBytes']:
            self.assertIn(requirement, source)
        self.assertNotIn('String(decoding:', source, 'No lossy UTF-8 substitution')
        self.assertGreaterEqual(source.count('try Task.checkCancellation()'), 5)

    def test_save_uses_exclusive_private_staging_then_single_atomic_commit(self):
        source = (CORE / 'TranscriptFileStore.swift').read_text()
        write = method(source, 'public static func write(_ text: String, to url: URL) throws {')
        for requirement in ['lstat($0, &info)', 'mkstemp(&template)',
                            'defer { if !committed { _ = unlink(temporary) } }',
                            'file.write(contentsOf: Data(text.utf8))', 'file.synchronize()',
                            'rename(temporary, $0)', 'committed = true']:
            self.assertIn(requirement, write)
        self.assertLess(write.index('file.synchronize()'), write.index('rename(temporary, $0)'))
        self.assertLess(write.rindex('try Task.checkCancellation()'), write.index('rename(temporary, $0)'))
        self.assertNotRegex(source, r'URLSession|UserDefaults|Timer|Task\.detached|createDirectory|NSPasteboard')

    def test_native_panels_and_replacement_confirmation_fail_closed(self):
        source = (APP / 'CoordinatorEnvironment.swift').read_text()
        self.assertIn('chooseTranscriptToOpen: @MainActor (UILanguage) -> URL? = { _ in nil }', source)
        self.assertIn('chooseTranscriptToSave: @MainActor (UILanguage) -> URL? = { _ in nil }', source)
        self.assertIn('confirmTranscriptReplacement: @MainActor (UILanguage) -> Bool = { _ in false }', source)
        dialogs = source.split('@MainActor\nenum NativeTranscriptDialogs {', 1)[1].split(
            '/// System boundaries only.', 1)[0]
        self.assertIn('let picker = NSOpenPanel()', dialogs)
        self.assertIn('let picker = NSSavePanel()', dialogs)
        self.assertEqual(dialogs.count('picker.allowedContentTypes = [.plainText]'), 2)
        self.assertIn('picker.nameFieldStringValue = root == nil ? "Transcript.txt" : "saved.txt"', dialogs)
        self.assertIn('guard picker.runModal() == .OK, let url = picker.url, accepts(url) else { return nil }', dialogs)
        confirmation = dialogs.split('static func confirmReplacement(ui: UILanguage) -> Bool {', 1)[1].split(
            'static func confirmQuit', 1)[0]
        self.assertLess(confirmation.index('ui.text("Abbrechen")'), confirmation.index('ui.text("Vorschau ersetzen")'))
        self.assertIn('alert.runModal() == .alertSecondButtonReturn', confirmation)
        quit_confirmation = dialogs.split('static func confirmQuit(ui: UILanguage)', 1)[1]
        self.assertIn('case .alertSecondButtonReturn: return .save', quit_confirmation)
        self.assertIn('case .alertThirdButtonReturn: return .discard', quit_confirmation)
        live = source.split('static func live(preferences: AppPreferences) -> Self {', 1)[1]
        self.assertIn('chooseTranscriptToOpen: { ui in NativeTranscriptDialogs.chooseOpen(ui: ui) }', live)
        self.assertIn('chooseTranscriptToSave: { ui in NativeTranscriptDialogs.chooseSave(ui: ui) }', live)
        self.assertIn('confirmTranscriptReplacement: { ui in NativeTranscriptDialogs.confirmReplacement(ui: ui) }', live)
        self.assertIn('confirmUnsavedReviewQuit: { ui in NativeTranscriptDialogs.confirmQuit(ui: ui) }', live)
        self.assertIn('try TranscriptFileStore.read($0)', source)
        self.assertIn('try TranscriptFileStore.write($0, to: $1)', source)
        qa = (APP / 'FunctionalQAContext.swift').read_text()
        self.assertIn('NativeTranscriptDialogs.chooseOpen(ui: ui, root: files.directory', qa)
        self.assertIn('NativeTranscriptDialogs.chooseSave(ui: ui, root: files.directory', qa)
        self.assertIn('accepts: files.acceptsOpenSelection', qa)
        self.assertIn('accepts: files.acceptsSaveSelection', qa)

    def test_open_commits_only_after_read_confirmation_and_freshness_recheck(self):
        source = (APP / 'AppCoordinator.swift').read_text()
        body = method(source, '    func openTranscript() {')
        for requirement in ['guard canOpenTranscript, let admission = transcriptAdmission.begin()',
                            'generation == cancellationGeneration', 'Task.detached(priority: .utility)',
                            'onCancel: { reading.cancel() }', 'session.id == previousID',
                            'if hasPendingReview || !editedText.isEmpty',
                            'environment.confirmTranscriptReplacement(uiLanguage)',
                            'guard session.openTranscript(text)', 'editedText = text; metrics = nil']:
            self.assertIn(requirement, body)
        self.assertEqual(body.count('TranscriptTextIdentity.matches(editedText, previousText)'), 2,
                         'Both pending-read checks compare exact draft bytes')
        self.assertLess(body.index('try await reading.value'), body.index('environment.confirmTranscriptReplacement'))
        self.assertLess(body.index('environment.confirmTranscriptReplacement'), body.index('session.openTranscript(text)'))
        self.assertEqual(len(re.findall(r'editedText\s*=(?!=)', body)), 1, 'No clearing the old draft before read/confirmation')
        self.assertNotIn('session.discard()', body)
        self.assertIn('(!isPresentationQA || launchConfiguration.isFunctionalQA) && !busy && microphone.state == .closed', source)

    def test_cancel_and_quit_preserve_admitted_file_review_until_worker_drains(self):
        source = (APP / 'AppCoordinator.swift').read_text()
        self.assertIn('transcriptAdmission.isHeld || session.phase.isBusy', source)
        self.assertEqual(source.count('if transcriptFilePending { cancelTranscriptFile(); return }'), 2)
        cancel = source.split('private func cancelTranscriptFile() {', 1)[1].split('\n    func unload()', 1)[0]
        self.assertIn('transcriptAdmission.invalidate(); cancellationGeneration &+= 1', cancel)
        self.assertIn('task?.cancel()', cancel)
        self.assertNotRegex(cancel, r'session\.(cancel|discard)|editedText\s*=|transcriptAdmission\.finish|capture\.cancel')
        self.assertIn('let pendingOperation = operationNeedsDrain ? task : nil', source)
        self.assertIn('await pendingOperation?.value', source)
        self.assertIn('if !preservingMessage, session.phase == .cancelled, !closePending', source)
        self.assertEqual(source.count('transcriptAdmission.finish(admission); finishOperation(preservingMessage: true)'), 2)
        saving = source.split('    private func saveTranscript(forQuit attempt: UUID?) {', 1)[1].split(
            '    private func cancelTranscriptFile()', 1)[0]
        finalizer = saving.split('            defer {', 1)[1].split('            do {', 1)[0]
        self.assertLess(finalizer.index('transcriptAdmission.finish(admission)'),
                        finalizer.index('finishQuitDecision(attempt, releaseStatisticsExport: false)'))
        self.assertLess(finalizer.index('beginQuit(preservingReview: true)'),
                        finalizer.index('releaseStatisticsExportQuitSave()'))
        self.assertLess(finalizer.index('finishOperation(preservingMessage: true)'),
                        finalizer.index('beginQuit(preservingReview: true)'))
        self.assertIn('if saved, hasPendingReview, session.id == reviewID,', finalizer)
        self.assertIn('TranscriptTextIdentity.matches(editedText, text), !hasUnsavedReview', finalizer)

    def test_save_snapshots_edited_text_and_has_no_review_mutation(self):
        source = (APP / 'AppCoordinator.swift').read_text()
        body = source.split('    func saveTranscript() {', 1)[1].split('    private func cancelTranscriptFile()', 1)[0]
        self.assertIn('saveTranscript(forQuit: nil)', body)
        for admission_guard in ['(!isPresentationQA || launchConfiguration.isFunctionalQA), !quitRequested',
                                '!operationPending, !closePending, !modelOperationPending',
                                '!importAdmission.isHeld, !audioImportAdmission.isHeld, !transcriptAdmission.isHeld',
                                'microphone.state == .closed, hasPendingReview',
                                'attempt == nil ? !quitDecisionPending : quitAttempt == attempt',
                                'let admission = transcriptAdmission.begin()']:
            self.assertIn(admission_guard, body)
        self.assertIn('let text = editedText, reviewID = session.id', body)
        self.assertIn('generation == cancellationGeneration, session.id == reviewID, hasPendingReview', body)
        self.assertIn('savedReviewID = reviewID; savedReviewText = text', body)
        self.assertIn('let text = editedText', body)
        self.assertIn('try write(text, url)', body)
        self.assertIn('onCancel: { writing.cancel() }', body)
        self.assertIn('message = TranscriptTextIdentity.matches(editedText, text)', body)
        self.assertNotRegex(body, r'editedText\s*=(?!=)|session\.(discard|cancel|openTranscript)|copyText|preferences')

    def test_editor_undo_identity_and_native_editability_follow_file_admission(self):
        source = (APP / 'Presentation.swift').read_text()
        self.assertIn('.id(coordinator.session.id)', source)
        self.assertIn('.disabled(coordinator.transcriptFilePending)', source)
        self.assertEqual(source.count('editor.isEditable = isEditable && isEnabled'), 2)
        self.assertIn('parent.isEditable && parent.isEnabled', source)
        self.assertIn('private let reviewUndoManager = UndoManager()', source)
        self.assertIn('func undoManager(for view: NSTextView) -> UndoManager?', source)
        self.assertIn('context.coordinator.clearUndoHistory()', source)
        self.assertIn('action: coordinator.openTranscript', source)
        self.assertIn('action: coordinator.saveTranscript', source)
        self.assertIn('.disabled(!coordinator.canSaveTranscript)', source)
        self.assertNotIn('CommandGroup', (APP / 'ClavuneApp.swift').read_text())

    def test_undo_completion_bridge_is_synchronous_private_and_detached(self):
        source = (APP / 'Presentation.swift').read_text()
        delegate = source.split('    final class Delegate: NSObject, NSTextViewDelegate {', 1)[1]
        delegate = delegate.split('\n}\n', 1)[0]
        for requirement in ['private weak var editor: NSTextView?',
                            'Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange',
                            'selector: #selector(historyDidChange(_:))',
                            'name: name, object: reviewUndoManager',
                            'changed === editor', 'editor.delegate === self',
                            'let text = editor.string', '!TranscriptTextIdentity.matches(parent.text, text)',
                            'parent.isEditable && parent.isEnabled',
                            'deinit { NotificationCenter.default.removeObserver(self) }']:
            self.assertIn(requirement, delegate)
        detached = delegate.split('func detach() {', 1)[1].split('\n        }', 1)[0]
        self.assertIn('NotificationCenter.default.removeObserver(self)', detached)
        self.assertIn('editor = nil', detached)
        self.assertIn('clearUndoHistory()', detached)
        self.assertIn('context.coordinator.attach(to: editor)', source)
        self.assertIn('coordinator.detach()', source)
        self.assertNotRegex(delegate, r'Task\s*\{|DispatchQueue|Timer|asyncAfter|sleep\(')
        self.assertNotIn('.didChangeText()', delegate)
        native = (ROOT / 'Tests/ClavuneCoreTests/TranscriptFileEditorTests.swift').read_text()
        self.assertIn('XCTAssertEqual(saved.value, ["opened file edited", "opened file"])', native)
        self.assertIn('XCTAssertEqual(fixture.coordinator.editedText, "opened file")', native)
        self.assertIn('XCTAssertEqual(fixture.coordinator.editedText, "shared panel")', native)
        self.assertIn('XCTAssertTrue(undo.canRedo)', native)
        self.assertIn('XCTAssertTrue(mainUndo.canRedo)', native)
        self.assertNotIn('.didChangeText()', native)

    def test_new_user_visible_strings_are_translated(self):
        translations = (APP / 'UILanguage.swift').read_text()
        for file in ['CoordinatorEnvironment.swift', 'AppCoordinator.swift', 'Presentation.swift']:
            source = (APP / file).read_text()
            texts = re.findall(r'ui\.text\("([^"\n]+)"\)', source)
            if file == 'AppCoordinator.swift':
                source = source.split('    func openTranscript() {', 1)[1].split('    func unload()', 1)[0]
                texts += re.findall(r'(?:message =|\?|:) "([^"\n]+)"', source)
            for text in texts:
                if text == "Deutsch":  # Existing language autonym intentionally stays German.
                    continue
                self.assertIn('"' + text + '":', translations)

    def test_native_tests_use_injected_resources_and_unique_synthetic_files(self):
        tests = (ROOT / 'Tests/ClavuneCoreTests/TranscriptFileCoordinatorTests.swift').read_text()
        store = (ROOT / 'Tests/ClavuneCoreTests/TranscriptFileStoreTests.swift').read_text()
        for evidence in ['testOpenNeedsNoModel', 'testPanelCancellationAndReadFailure',
                         'testReplacementRequiresConfirmationEvenForEmptyReview',
                         'testFailedOpenAfterCancelledSession',
                         'testNestedPickerCommandsAreRejected', 'testCancellationAndPrivacyInterrupt',
                         'testEditsDuringReadAndCancelDuringConfirmation', 'testExplicitSaveUsesEditedSnapshot',
                         'testWriteFailureAndNewerEdits', 'testBusyAndPresentationQARejectPanels',
                         'testQuitWaitsForAdmittedRead']:
            self.assertIn(evidence, tests)
        self.assertIn('FileManager.default.temporaryDirectory', tests)
        self.assertIn('UUID().uuidString', store)
        for evidence in ['testUTF8RoundTrip', 'testExactSizeLimitAccepted', 'testMalformedUTF8Rejected',
                         'testNonFileURLsMissingFilesDirectoriesAndSymlinks', 'testFIFOReadAndWrite',
                         'testUnavailableDestination', 'testCancelledReadAndSave', 'testOpenedTextHasNewReviewIdentity']:
            self.assertIn(evidence, store)
        self.assertNotRegex(tests + store, r'NSPasteboard|NSOpenPanel|NSSavePanel|NSAlert|sleep\(')


if __name__ == '__main__':
    unittest.main()
