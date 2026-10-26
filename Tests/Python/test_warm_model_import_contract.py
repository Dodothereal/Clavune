"""Portable source contracts; NOT Swift execution, model hashing or latency evidence."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class WarmModelImportContracts(unittest.TestCase):
    def test_reuse_requires_all_verified_selected_identity_fields(self):
        app = (ROOT / 'Sources/ClavuneApp/AppCoordinator.swift').read_text()
        body = app.split('    func importModel() {', 1)[1].split('    func downloadModel(', 1)[0]
        condition = body.split('let preservesWarmModel = ', 1)[1].split('\n                if ', 1)[0]
        self.assertEqual(' '.join(condition.split()),
            'installed.reusedVerifiedFile && model?.sha256 == installed.candidate.sha256 && '
            'model?.sizeBytes == installed.candidate.sizeBytes && modelURL == installed.url')
        self.assertIn('if !preservesWarmModel {\n                    await inference.unload()', body)
        self.assertEqual(body.count('generation == cancellationGeneration'), 4)
        self.assertLess(body.index('try await importTask.value'), body.index('let preservesWarmModel'))
        self.assertLess(body.index('guard !Task.isCancelled'), body.index('let preservesWarmModel'))
        success = body.split('            } catch {', 1)[0]
        self.assertLess(success.index('await inference.unload()'), success.rindex('guard !Task.isCancelled'))
        self.assertLess(success.rindex('guard !Task.isCancelled'), success.index('model = installed.candidate'))
        self.assertIn('onCancel: { importTask.cancel() }', body)
        self.assertIn('importAdmission.finish(admission); modelOperationPending = false; finishOperation()', body)
        self.assertIn('modelOperationPending = true', body)
        self.assertLess(body.index('modelOperationPending = true'), body.index('environment.chooseModel()'))

    def test_cancelled_replacement_of_selected_path_drains_cache_before_return(self):
        app = (ROOT / 'Sources/ClavuneApp/AppCoordinator.swift').read_text()
        body = app.split('    func importModel() {', 1)[1].split('    func downloadModel(', 1)[0]
        branch = body.split('guard !Task.isCancelled, generation == cancellationGeneration else {', 1)[1]
        branch = branch.split('                // Reuse only', 1)[0]
        self.assertIn('if !installed.reusedVerifiedFile, modelURL == installed.url {', branch)
        self.assertIn('await inference.unload()', branch)
        self.assertLess(branch.index('await inference.unload()'), branch.index('return'))
        self.assertNotIn('model =', branch)
        self.assertNotIn('preferences?.set', branch)
        native = (ROOT / 'Tests/ClavuneCoreTests/WarmModelImportTests.swift').read_text()
        self.assertIn('testCancelledSameHashRecoveryDrainsOldCacheBeforeRetryCanReuseReplacement', native)
        self.assertIn('if calls.value == 2', native)
        self.assertIn('else if calls.value == 3', native)
        self.assertIn('before + 1', native)

    def test_import_boundary_is_detached_and_synthetic_default_fails_closed(self):
        app = (ROOT / 'Sources/ClavuneApp/AppCoordinator.swift').read_text()
        environment = (ROOT / 'Sources/ClavuneApp/CoordinatorEnvironment.swift').read_text()
        self.assertIn('let importModel = environment.importManagedModel\n'
                      '                let importTask = Task.detached(priority: .utility) {\n'
                      '                    try importModel(selected)', app)
        self.assertIn('var importManagedModel: @Sendable (URL) throws -> ModelStore.Installed = { _ in\n'
                      '        throw DictationError.modelInvalid', environment)
        live = environment.split('static func live(', 1)[1]
        self.assertIn('let candidates = try ModelStore.candidates()', live)
        self.assertIn('ProductIdentity.modelDirectory', live)
        self.assertIn('ModelStore.importModel(selected, into: destination, candidates: candidates)', live)

    def test_only_actual_existing_verified_reuse_sets_provenance_true(self):
        store = (ROOT / 'Sources/ClavuneCore/ModelStore.swift').read_text()
        self.assertEqual(store.count('reusedVerifiedFile: true'), 1)
        true_branch = store.split('reusedVerifiedFile: true', 1)[0]
        self.assertIn('_ = try verify(destination, candidates: [candidate])', true_branch)
        self.assertIn('try verify(temporary, candidates: candidates)', true_branch)
        self.assertIn('init(url: URL, candidate: ModelCandidate, reusedVerifiedFile: Bool = false)', store)
        recovery = store.split('try activateRecovery(temporary, replacing: destination, in: directory)', 1)[1]
        self.assertIn('return Installed(url: destination, candidate: candidate)', recovery)
        self.assertNotIn('reusedVerifiedFile: true', recovery)
        for guard in ['originalInode == currentInode, originalVolume == currentVolume',
                      'throw RecoveryError.unsafeExistingEntry', 'try Task.checkCancellation()',
                      'try renameWithoutReplacing(temporary, to: destination)']:
            self.assertIn(guard, store)

    def test_authored_native_cases_cover_reuse_switch_recovery_and_stale_result(self):
        native = (ROOT / 'Tests/ClavuneCoreTests/WarmModelImportTests.swift').read_text()
        for case in ['testSameVerifiedSelectedFileSkipsUnloadAfterActualCopyAndHash',
                     'testDifferentVerifiedModelUnloadsEvenWhenItsManagedFileAlreadyExists',
                     'testSameHashAtDifferentManagedURLStillUnloads',
                     'testSameHashRecoveryReplacesInodeAndStillUnloads',
                     'testMutatedIncomingBytesFailWithoutChangingSelectionOrUnloading',
                     'testPickerCancellationPreservesSelectionAndCache',
                     'testCancelledImportDrainsRejectsLateDifferentModelAndPreservesPriorCache',
                     'testCancellationDuringDifferentModelUnloadRejectsLateSelection']:
            self.assertIn(case, native)
        self.assertIn('ModelStore.importModel(url, into:', native)
        self.assertIn('waitUntilSuspended()', native)
        self.assertNotRegex(native, r'NSOpenPanel|NSPasteboard|NSApp|UserDefaults\.standard|sleep\(')


if __name__ == '__main__':
    unittest.main()
