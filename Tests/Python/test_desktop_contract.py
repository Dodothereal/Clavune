"""Portable source contracts only, not substitutes for macOS compile/runtime/visual QA."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / 'Sources/ClavuneApp'


class DesktopSourceContracts(unittest.TestCase):
    def test_window_and_optional_menu_share_one_coordinator(self):
        source = (APP / 'ClavuneApp.swift').read_text()
        self.assertIn('Window(ProductIdentity.displayName, id: "main")', source)
        self.assertIn('MenuBarExtra(isInserted: Binding(', source)
        self.assertIn('get: { scenePresentation.menuBarEnabled }', source)
        self.assertIn('set: { coordinator.menuBarEnabled = $0 }', source)
        self.assertEqual(source.count('AppCoordinator(policy:'), 1)
        self.assertIn('NSApp.setActivationPolicy(.regular)', source)
        self.assertIn('bringMainWindowToFront: @MainActor (NSWindow) -> Void = { $0.makeKeyAndOrderFront(nil) }', source)
        reopen = source.split('func applicationShouldHandleReopen(', 1)[1].split(
            'func applicationShouldTerminateAfterLastWindowClosed(', 1)[0]
        self.assertIn('if let mainWindow { bringMainWindowToFront(mainWindow) }', reopen)
        self.assertLess(reopen.index('bringMainWindowToFront(mainWindow)'), reopen.index('handoffToMainWindow()'))
        self.assertLess(reopen.index('handoffToMainWindow()'), reopen.index('activateApplication(sender)'))
        self.assertIn('self.coordinator?.revealPanelIfBusy()', source)

    def test_quit_approval_is_after_unload(self):
        source = (APP / 'AppCoordinator.swift').read_text().split('    func quit() {', 1)[1]
        self.assertLess(source.index('await pendingOperation?.value'), source.index('terminationReady = true'))
        self.assertLess(source.index('await inference.unload()'), source.index('terminationReady = true'))
        self.assertLess(source.index('terminationReady = true'), source.index('environment.terminate()'))
        self.assertIn('!coordinator.terminationReady', (APP / 'ClavuneApp.swift').read_text())

    def test_status_and_error_translation_coverage(self):
        language = (APP / 'UILanguage.swift').read_text()
        keys = set(re.findall(r'^        "([^"\n]+)":', language, re.M))
        source = (APP / 'AppCoordinator.swift').read_text()
        diagnostics = re.findall(r'(?:message|modelStatus|hotkeyStatus) = "([^"\n]+)"', source)
        for core in ['Policy.swift', 'ModelStore.swift']:
            diagnostics += re.findall(r'return "([^"\n]+)"', (ROOT / 'Sources/ClavuneCore' / core).read_text())
        for text in diagnostics:
            with self.subTest(text=text):
                if text == r"\(candidate.fileName): \(received) / \(candidate.sizeBytes) Bytes":
                    self.assertIn('source.hasSuffix(" Bytes")', language)
                    self.assertIn('return "\\(name): \\(received) / \\(total) bytes"', language)
                    continue
                self.assertIn(text, keys)
        presentation = (APP / 'Presentation.swift').read_text()
        for text in re.findall(r'ui.text\("([^"\n]+)"\)', presentation):
            if text not in ['Deutsch', 'English']:
                with self.subTest(label=text):
                    self.assertIn(text, keys)

    def test_recognition_preference_is_separate_and_restores_with_safe_default(self):
        source = (APP / 'AppCoordinator.swift').read_text()
        self.assertIn('didSet { preferences?.set(language.rawValue, forKey: "recognitionLanguage") }', source)
        self.assertIn('language = LanguageMode(rawValue: selectedPreferences?.string(forKey: "recognitionLanguage") ?? "") ?? .auto', source)
        self.assertIn('uiLanguage = UILanguage(rawValue: selectedPreferences?.string(forKey: "uiLanguage") ?? "") ?? .english', source)
        self.assertNotIn('UserDefaults.standard', source)

    def test_no_model_start_screen_distinguishes_local_selection_download_and_import(self):
        presentation = (APP / 'Presentation.swift').read_text()
        guidance = (APP / 'ModelImportGuidance.swift').read_text()
        self.assertIn('onDownload: coordinator.downloadModel', presentation)
        self.assertIn('onCheckInstalled: coordinator.checkInstalledModels', presentation)
        self.assertIn('onSelectInstalled: coordinator.selectInstalledModel', presentation)
        self.assertIn('action: coordinator.importModel', presentation)
        self.assertIn('allowsDownload: !coordinator.isPresentationQA', presentation)
        self.assertIn('State(initialValue: isSetup)', guidance)
        self.assertIn('isExpanded: $expanded', guidance)
        self.assertIn('Button(ui.text("Lokale Modelle prüfen (kein Download)"), action: onCheckInstalled)', guidance)
        local = guidance.split('} else if isVerified {', 1)[1].split(
            '} else if candidate.downloadEnabled {', 1)[0]
        self.assertIn('onSelectInstalled(candidate)', local)
        self.assertNotIn('onDownload(candidate)', local)
        self.assertIn('Button(ui.text("Herunterladen und prüfen")) { onDownload(candidate) }', guidance)
        self.assertIn('isSelected && localModelInventoryChecked ? "Ausgewählt; lokale Datei ungültig oder nicht verfügbar"', guidance)
        self.assertIn('localModelInventoryChecked ? "Lokal nicht bereit" : "Nicht geprüft"', guidance)
        self.assertIn('Text(ui.text(coordinator.modelStatus))', presentation)

    def test_model_download_failures_use_the_selected_interface_language(self):
        language = (APP / 'UILanguage.swift').read_text()
        coordinator = (APP / 'AppCoordinator.swift').read_text()
        self.assertIn('func downloadFailureMessage(for error: Error) -> String', language)
        self.assertIn('error as? ModelDownloadFailure', language)
        self.assertIn('error as? ModelStore.RecoveryError', language)
        self.assertIn('error is URLError', language)
        self.assertIn('message = uiLanguage.downloadFailureMessage(for: error)', coordinator)
        for diagnostic in [
            'Für dieses Modell gibt es keine geprüfte Downloadquelle.',
            'Der Modelldownload wurde unterbrochen. Prüfe die Verbindung und wähle den Download erneut; Teildaten werden nur bei passender Quellenprüfung fortgesetzt.',
            'Der Modelldownload ist fehlgeschlagen. Bitte prüfe Verbindung und Speicherplatz und versuche es erneut.',
        ]:
            self.assertIn(diagnostic, language)

    def test_qa_registration_fixture_restores_process_defaults(self):
        test = (ROOT / 'Tests/ClavuneCoreTests/AppLaunchConfigurationTests.swift').read_text()
        body = test.split('func testQAReadDoesNotFallBackToRegistrationAndWriteStaysInItsDomain()', 1)[1].split('@MainActor', 1)[0]
        snapshot = 'let defaults = try XCTUnwrap(preferences.defaults)\n        let suite = try XCTUnwrap(config.preferenceSuite)'
        self.assertIn(snapshot, body)
        self.assertLess(body.index(snapshot), body.index('defaults.register(defaults:'))
        cleanup = body.split('defer {', 1)[1].split('}', 1)[0]
        self.assertIn('removePersistentDomain(forName: suite)', cleanup)
        self.assertIn('removeVolatileDomain(forName: UserDefaults.registrationDomain)', cleanup)
        self.assertIn('setVolatileDomain(registration, forName: UserDefaults.registrationDomain)', cleanup)
        retry = (ROOT / 'Tests/ClavuneCoreTests/SavedModelRetryTests.swift').read_text()
        self.assertIn('XCTAssertNil(defaults.object(forKey: "selectedModelSHA256")', retry)

    def test_saved_model_retry_admission_and_localized_action(self):
        source = (APP / 'AppCoordinator.swift').read_text()
        admission = source.split('var canRestoreManagedModel: Bool {', 1)[1].split('    func attachPanel', 1)[0]
        for gate in ['!isPresentationQA', '!busy', '!hasPendingReview', 'microphone.state == .closed', 'model == nil', 'selectedModelSHA256']:
            self.assertIn(gate, admission)
        restore = source.split('    func restoreManagedModel() {', 1)[1].split('    func start()', 1)[0]
        self.assertIn('guard canRestoreManagedModel,', restore)
        self.assertIn('if session.phase == .cancelled { session.discard() }', restore)
        self.assertLess(restore.index('guard canRestoreManagedModel,'), restore.index('session.discard()'))
        self.assertIn('operationPending = true; operationNeedsDrain = true', restore)
        self.assertIn('environment.restoreManagedSelection', restore)
        view = (APP / 'Presentation.swift').read_text()
        self.assertIn('action: coordinator.restoreManagedModel', view)
        self.assertIn('.disabled(!coordinator.canRestoreManagedModel)', view)
        self.assertIn('"Gespeichertes Modell erneut prüfen": "Retry saved model"', (APP / 'UILanguage.swift').read_text())

    def test_restore_boundary_fails_closed_and_live_verifies_without_creation(self):
        source = (APP / 'CoordinatorEnvironment.swift').read_text()
        default = source.split('var restoreManagedSelection:', 1)[1].split('static func live', 1)[0]
        self.assertIn('throw DictationError.modelInvalid', default)
        self.assertNotIn('FileManager', default)
        live = source.split('static func live', 1)[1]
        self.assertIn('create: false', live)
        self.assertIn('ModelStore.restoreSelection(hash, in: directory, candidates: ModelStore.candidates())', live)

    def test_restore_is_explicit_off_main_and_read_only(self):
        source = (APP / 'AppCoordinator.swift').read_text().split('    func restoreManagedModel() {', 1)[1].split('    func start() {', 1)[0]
        self.assertIn('preferences?.string(forKey: "selectedModelSHA256")', source)
        self.assertIn('Task.detached(priority: .utility)', source)
        self.assertIn('onCancel: { verification.cancel() }', source)
        self.assertIn('generation == cancellationGeneration', source)
        self.assertNotIn('inference.load', source)
        core = (ROOT / 'Sources/ClavuneCore/ModelStore.swift').read_text().split('public static func restoreSelection(', 1)[1].split('/// A single managed backup', 1)[0]
        self.assertIn('try verify(url, candidates: [candidate])', core)
        self.assertNotRegex(core, r'rename|write|removeItem|importModel')

    def test_responsive_presentation_retains_reduce_motion_and_shared_hotkey(self):
        source = (APP / 'Presentation.swift').read_text()
        self.assertNotIn('.frame(width: 440)', source)
        self.assertNotIn('.animation(', source)
        self.assertIn('set: { coordinator.setHotkeyEnabled($0) }', source)
        self.assertIn('selection: $coordinator.uiLanguage', source)
        self.assertIn('selection: $coordinator.language', source)
        self.assertIn('ScrollView {', source)

    def test_auxiliary_dismissal_and_main_handoff_keep_capture_controls(self):
        presentation = (APP / 'Presentation.swift').read_text()
        coordinator = (APP / 'AppCoordinator.swift').read_text()
        lifecycle = (APP / 'ClavuneApp.swift').read_text()
        self.assertIn('if isAuxiliaryPanel {', presentation)
        self.assertIn('.disabled(!coordinator.canHidePanel)', presentation)
        self.assertIn('isAuxiliaryPanel: true', presentation)
        self.assertIn('var canHidePanel: Bool { !busy && microphone.state == .closed }', coordinator)
        self.assertIn('guard canHidePanel else { return }', coordinator)
        self.assertIn('guard isVisible else { return }', coordinator)
        self.assertIn('NSWindow.didBecomeKeyNotification', lifecycle)
        self.assertIn('mainWindow?.isVisible == true && mainWindow?.isMiniaturized == false', lifecycle)
        self.assertIn('self.mainWindow?.isVisible != true', lifecycle)

    def test_explicit_qa_launch_isolated_and_blocks_model_and_capture_paths(self):
        config = (APP / 'AppLaunchConfiguration.swift').read_text()
        coordinator = (APP / 'AppCoordinator.swift').read_text()
        environment = (APP / 'CoordinatorEnvironment.swift').read_text()
        self.assertIn('environment["CLAVUNE_QA_PROFILE"]', config)
        self.assertIn('(1...32).contains(profile.count)', config)
        self.assertIn('throw ConfigurationError.invalidQAProfile', config)
        self.assertIn('"org.clavune.DevelopmentQA." + $0', config)
        self.assertIn('defaults.persistentDomain(forName: isolatedSuite)?[key]', config)
        self.assertIn('var canStart: Bool {', coordinator)
        self.assertIn('!isPresentationQA && !busy && model != nil && !hasPendingReview && !microphoneModelNeedsRevalidation', coordinator)
        self.assertIn('guard !isPresentationQA, !busy, let admission', coordinator)
        self.assertIn('!isPresentationQA && !busy && !hasPendingReview', coordinator)
        self.assertIn('guard canRestoreManagedModel,', coordinator)
        self.assertNotIn('UserDefaults.standard', environment)
        self.assertIn('preferences.string(forKey: "uiLanguage")', environment)
        presentation = (APP / 'Presentation.swift').read_text()
        self.assertIn('if coordinator.launchConfiguration.isQA {', presentation)
        self.assertIn('.accessibilityLabel(ui.text("Synthetischer QA-Modus"))', presentation)
        self.assertNotIn('coordinator.launchConfiguration.qaProfile', presentation)

    def test_native_quit_uses_delegate_without_dynamic_scene_command_builder(self):
        source = (APP / 'ClavuneApp.swift').read_text()
        self.assertNotIn('.commands {', source)
        self.assertNotIn('CommandGroup(', source)
        self.assertIn('func applicationShouldTerminate(', source)
        self.assertIn('guard let coordinator, !coordinator.terminationReady', source)
        self.assertIn('coordinator.quit()', source)
        self.assertIn('return .terminateCancel', source)

    def test_scene_observes_only_installation_state_and_leaves_observe_coordinator(self):
        source = (APP / 'ClavuneApp.swift').read_text()
        self.assertIn('@State private var coordinator: AppCoordinator', source)
        self.assertNotIn('@StateObject private var coordinator:', source)
        self.assertIn('@StateObject private var scenePresentation: ScenePresentationState', source)
        self.assertIn('StateObject(wrappedValue: coordinator.scenePresentation)', source)
        self.assertIn('MenuBarStatusLabel(coordinator: coordinator)', source)
        self.assertIn('private struct MenuBarStatusLabel: View {\n    @ObservedObject var coordinator:', source)
        state = (APP / 'ScenePresentationState.swift').read_text()
        self.assertEqual(state.count('@Published'), 1)
        self.assertIn('guard menuBarEnabled != enabled else { return }', state)

    def test_pending_review_blocks_new_start_before_any_resource_or_text_mutation(self):
        source = (APP / 'AppCoordinator.swift').read_text()
        self.assertIn('var hasPendingReview: Bool { session.phase == .review }', source)
        self.assertIn('model != nil && !hasPendingReview', source)
        start = source.split('    func start() {', 1)[1].split('    func stop() {', 1)[0]
        guard = start.index('guard !hasPendingReview else {')
        for side_effect in ['session.begin(', 'editedText = ""', 'environment.makeCancellation']:
            self.assertLess(guard, start.index(side_effect))
        self.assertIn('panel?.show(force: false)', start[:start.index('guard canStart')])

    def test_copy_command_uses_explicit_boundary_and_live_retains_host_only_policy(self):
        coordinator = (APP / 'AppCoordinator.swift').read_text()
        copy = coordinator.split('    func copy() {', 1)[1].split('    func unload() {', 1)[0]
        self.assertIn('guard session.phase == .review, !editedText.isEmpty', copy)
        self.assertIn('environment.copyText(editedText)', copy)
        self.assertNotIn('session.discard', copy)
        self.assertNotIn('LocalClipboard.copy', copy)
        environment = (APP / 'CoordinatorEnvironment.swift').read_text()
        self.assertIn('var copyText: @MainActor (String) -> Bool = { _ in false }', environment)
        self.assertIn('copyText: { LocalClipboard.copy($0) }', environment)
        fixture = (ROOT / 'Tests/ClavuneCoreTests/CoordinatorFixtures.swift').read_text()
        self.assertIn('LocalClipboard.copy($0, using: self.clipboard)', fixture)
