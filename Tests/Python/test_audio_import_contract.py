"""Portable source gates only; not Swift/macOS execution or audio-quality evidence."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / 'Sources/ClavuneApp'
CORE = ROOT / 'Sources/ClavuneCore'


class AudioImportContracts(unittest.TestCase):
    def test_reader_bounds_descriptor_callbacks_and_reuses_existing_converter(self):
        source = (CORE / 'AudioFileImporter.swift').read_text()
        for term in ['maximumBytes = 64 * 1024 * 1024', 'url.isFileURL',
                     'O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC', 'fstat(opened, &info)',
                     'mode_t(S_IFREG)', 'AudioFileOpenWithCallbacks', 'case kAudioFileWAVEType:',
                     'format.mFormatID == kAudioFormatLinearPCM', '(1...2).contains(format.mChannelsPerFrame)',
                     '(8000...192000).contains(format.mSampleRate)', 'format.mSampleRate * Double(policy.sessionLimitSeconds)',
                     'declaredFrames <= frameLimit',
                     'AudioConversion(sourceRate:', 'try conversion.append(', 'try conversion.finish()',
                     'consumed <= frameLimit', 'consumed != declaredFrames', 'try source.requireUnchanged()',
                     'remainingReadBytes = AudioFileImporter.maximumBytes * 4',
                     'min(Int64(requested), size - position)', 'pread(descriptor, buffer, Int(count)',
                     'policy.sampleRate == 16000', '(128...16384).contains(policy.maxNativeBlockFrames)']:
            self.assertIn(term, source)
        self.assertGreaterEqual(source.count('try Task.checkCancellation()'), 5)
        self.assertNotRegex(source, r'URLSession|UserDefaults|Timer|write\(|createDirectory|Data\(contentsOf|AVAudioEngine')

    def test_reader_ownership_drains_in_reverse_order_without_disk_copy(self):
        source = (CORE / 'AudioFileImporter.swift').read_text()
        positions = [source.index(x) for x in ['defer { source.close() }', 'defer { AudioFileClose(file) }',
                                               'defer { ExtAudioFileDispose(reader) }', 'defer { samples.deallocate() }']]
        self.assertEqual(positions, sorted(positions))
        self.assertIn('ExtAudioFileWrapAudioFileID(file, false, &wrapped)', source)
        self.assertIn('deinit { close() }', source)
        self.assertIn('descriptor = -1', source)
        self.assertNotRegex(source, r'mkstemp|FileHandle\(forWriting|write\(contentsOf|AudioFileWrite|ExtAudioFileWrite')

    def test_coordinator_admission_review_and_qa_safety(self):
        source = (APP / 'AppCoordinator.swift').read_text()
        audio_admission = source.split('var canImportAudio: Bool {', 1)[1].split('    var transcriptFilePending:', 1)[0]
        self.assertIn('canStart || (launchConfiguration.isFunctionalQA && !busy && model != nil && !hasPendingReview)', audio_admission)
        self.assertIn('microphone.state == .closed', audio_admission)
        configuration = (APP / 'AppLaunchConfiguration.swift').read_text()
        self.assertIn('functional == nil || functional == "synthetic-v1"', configuration)
        factory = source.split('convenience init(', 1)[1].split('    init(policy:', 1)[0]
        self.assertLess(factory.index('if launchConfiguration.isFunctionalQA'), factory.index('environment: .live'))
        self.assertIn('environment: context.environment(', factory)
        self.assertIn('!isPresentationQA && !busy && model != nil && !hasPendingReview', source)
        self.assertIn('audioImportAdmission.isHeld', source)
        body = source.split('    func importAudio() {', 1)[1].split('    private func cancelAudioImport()', 1)[0]
        self.assertLess(body.index('audioImportAdmission.begin()'), body.index('environment.chooseAudioToImport'))
        self.assertLess(body.index('environment.chooseAudioToImport'), body.index('session.begin(preparing:'))
        self.assertLess(body.index('try await reading.value'), body.index('inference.load('))
        self.assertLess(body.index('inference.load('), body.index('inference.transcribe('))
        self.assertGreaterEqual(body.count('generation == cancellationGeneration'), 5)
        self.assertIn('onCancel: { reading.cancel() }', body)
        self.assertIn('session.transcribingImportedAudio(id)', body)
        self.assertNotRegex(body, r'capture\.|requestPermission|permissionStatus|startPrivacyWatchdog|copyText|writeTranscript')

    def test_cancel_and_quit_hold_admission_until_actual_worker_completion(self):
        source = (APP / 'AppCoordinator.swift').read_text()
        self.assertEqual(source.count('if audioFilePending { cancelAudioImport(); return }'), 2)
        body = source.split('    private func cancelAudioImport() {', 1)[1].split('\n    /// No admission', 1)[0]
        self.assertIn('audioImportAdmission.invalidate(); cancellationGeneration &+= 1', body)
        self.assertIn('cancellation?.cancel(); task?.cancel()', body)
        self.assertNotRegex(body, r'audioImportAdmission\.finish|finishOperation|capture\.cancel')
        self.assertIn('let pendingOperation = operationNeedsDrain ? task : nil', source)
        self.assertIn('await pendingOperation?.value', source)
        self.assertIn('operationPending = true; operationNeedsDrain = true', source)

    def test_stop_command_boundary_rejects_file_work_before_any_stop_side_effect(self):
        source = (APP / 'AppCoordinator.swift').read_text()
        stop = source.split('    func stop() {', 1)[1].split('    func interruptForPrivacy()', 1)[0]
        self.assertLess(stop.index('guard !audioFilePending else { return }'), stop.index('environment.nowHostTime()'))
        self.assertLess(stop.index('guard !audioFilePending else { return }'), stop.index('if session.phase == .preparing'))
        native = (ROOT / 'Tests/ClavuneCoreTests/AudioFileCoordinatorTests.swift').read_text()
        self.assertIn('testHoldHotkeyReleaseDuringImportCannotCancelUnstartedRecording', native)
        self.assertIn('registration.send(down: true); registration.send(down: false)', native)

    def test_native_picker_uses_supported_formats_and_synthetic_boundary_fails_closed(self):
        source = (APP / 'CoordinatorEnvironment.swift').read_text()
        self.assertIn('chooseAudioToImport: @MainActor (UILanguage) -> URL? = { _ in nil }', source)
        self.assertIn('var readAudio: @Sendable (URL, ResourcePolicy) throws -> SessionPCM', source)
        self.assertIn('picker.allowedContentTypes = [.mpeg4Audio, .mp3, .wav]', source)
        self.assertIn('readAudio: { try AudioFileImporter.read($0, policy: $1) }', source)
        ui = (APP / 'Presentation.swift').read_text()
        self.assertIn('action: coordinator.importAudio', ui)
        self.assertIn('.disabled(!coordinator.canImportAudio)', ui)
        self.assertIn('if coordinator.canStop {', ui)
        self.assertIn('Button(ui.text("Stoppen"), action: coordinator.stop)', ui)
        self.assertNotIn('CommandGroup', (APP / 'ClavuneApp.swift').read_text())
        menu = (APP / 'ClavuneApp.swift').read_text()
        self.assertIn('.disabled(!coordinator.canStop)', menu)
        action = (APP / 'AppCoordinator.swift').read_text()
        self.assertIn('var canStop: Bool {', action)
        self.assertIn('!audioFilePending && [.preparing, .recording].contains(session.phase)', action)

    def test_file_failure_guidance_does_not_suggest_microphone_recovery(self):
        recovery = (APP / 'DictationRecovery.swift').read_text()
        self.assertIn('audioFileSession ? nil : DictationRecovery(session: session)', recovery)
        source = (APP / 'AppCoordinator.swift').read_text()
        self.assertEqual(source.count('audioFileSession = false'), 4)  # declaration, record, discard, text-open
        self.assertIn('audioFileSession = true', source)
        language = (APP / 'UILanguage.swift').read_text()
        body = source.split('    func importAudio() {', 1)[1].split('\n    /// No admission', 1)[0]
        for text in re.findall(r'(?:message =|\?|:) "([^"\n]+)"', body):
            self.assertIn('"' + text + '":', language)

    def test_native_codec_and_stereo_policy_are_explicit_not_extension_trust(self):
        source = (CORE / 'AudioFileImporter.swift').read_text()
        for term in ['}, nil, 0, &opened)', 'kAudioFileM4AType', 'kAudioFileAAC_ADTSType',
                     'kAudioFormatMPEG4AAC', 'kAudioFormatAppleLossless', 'kAudioFileMP3Type',
                     'kAudioFormatMPEGLayer3', 'kAudioFilePropertyPacketTableInfo',
                     'table.mNumberValidFrames <= frameLimit', 'capacity * channels',
                     'try mixToMonoInPlace(samples, frames: Int(count), channels: channels)',
                     'left * 0.5 + right * 0.5', 'right.isFinite']:
            self.assertIn(term, source)
        self.assertIn('if isPCM, consumed != declaredFrames', source)
        self.assertNotIn('AVAudioConverter', source, 'Do not add a second sample-rate conversion path')

    def test_real_codec_fixture_bytes_are_small_generated_hashed_and_test_only(self):
        import base64
        import hashlib
        import json
        path = ROOT / 'Tests/ClavuneCoreTests/Fixtures/synthetic-audio-formats.json'
        data = json.loads(path.read_text())
        self.assertIn('generated', data['purpose'])
        self.assertEqual({f['name'] for f in data['fixtures']}, {'m4a', 'aac', 'mp3', 'alac'})
        for fixture in data['fixtures']:
            raw = base64.b64decode(fixture['base64'], validate=True)
            self.assertEqual(len(raw), fixture['bytes'])
            self.assertEqual(hashlib.sha256(raw).hexdigest(), fixture['sha256'])
            self.assertLess(len(raw), 8192)
            self.assertIn('no speech or user data', fixture['source'])
            self.assertEqual(fixture['probe']['streams'][0]['channels'], 1 if fixture['name'] == 'm4a' else 2)
        package = (ROOT / 'Package.swift').read_text()
        self.assertIn('resources: [.copy("Fixtures")]', package.split('.testTarget', 1)[1])
        production = ''.join(p.read_text() for p in (ROOT / 'Sources').rglob('*.swift'))
        self.assertNotRegex(production, r'ffmpeg|synthetic-audio-formats|libmp3lame')
        native = (ROOT / 'Tests/ClavuneCoreTests/CompressedAudioImporterTests.swift').read_text()
        for term in ['AudioFileImporter.read(url, policy: policy)', 'result.samples.count',
                     'let rms =', 'testSmallCompressedStreamCannotExceedActualDecodedDurationLimit',
                     'testBrokenCompressedHeaders', 'No app decoder dependency',
                     'testGeneratedMonoM4AReachesReviewThroughActualImporterAndCoordinator',
                     'fixture.coordinator.importAudio(); await waitForOperation(fixture)',
                     'fixture.inference.receivedPCM.value']:
            self.assertIn(term, native)

    def test_import_timing_includes_preparation_and_total_not_only_asr_decode(self):
        source = (APP / 'AppCoordinator.swift').read_text()
        body = source.split('    func importAudio() {', 1)[1].split('    private func cancelAudioImport()', 1)[0]
        self.assertLess(body.index('try await reading.value'), body.index('metrics?.audioPreparationSeconds'))
        self.assertLess(body.index('metrics?.audioPreparationSeconds'), body.index('inference.load('))
        self.assertLess(body.index('inference.transcribe('), body.index('metrics?.audioImportTotalSeconds'))
        self.assertIn('prepared - requested', body)
        self.assertIn('finished - requested', body)
        ui = (APP / 'Presentation.swift').read_text()
        self.assertIn('metrics.audioPreparationSeconds', ui)
        self.assertIn('metrics.audioImportTotalSeconds', ui)
        native = (ROOT / 'Tests/ClavuneCoreTests/AudioFileCoordinatorTests.swift').read_text()
        self.assertIn('testImportTimingsIncludeFilePreparationAndModelWaitBeforeResult', native)

    def test_authored_native_coverage_is_synthetic_and_not_claimed_as_run(self):
        native = (ROOT / 'Tests/ClavuneCoreTests/AudioFileImporterTests.swift').read_text()
        coordinator = (ROOT / 'Tests/ClavuneCoreTests/AudioFileCoordinatorTests.swift').read_text()
        for term in ['testMonoPCM16', 'testMonoUnsigned8', 'testMultichannelUnsupportedRate',
                     'testNonFiniteFloat', 'testExactDuration', 'testByteLimit', 'testNonFileURL',
                     'testDescriptorPins', 'testConcurrentGrowth', 'testCancelledImport',
                     'testImportedSessionTransition']:
            self.assertIn(term, native)
        for term in ['testImportReachesExisting', 'testPendingReviewEvenEmpty', 'testMissingModelBusy',
                     'testPickerCancel', 'testNestedPickerCommands', 'testReadFailure',
                     'testModelAndDecoderFailures', 'testCancelAndPrivacyDuringRead',
                     'testCancelDuringModelLoad', 'testQuitWaitsForReadDrain', 'testDiscardImportedReview']:
            self.assertIn(term, coordinator)
        self.assertIn('UUID().uuidString', native)
        self.assertNotRegex(native + coordinator, r'NSPasteboard|NSOpenPanel|NSSavePanel|NSAlert|sleep\(')


if __name__ == '__main__':
    unittest.main()
