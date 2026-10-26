"""Portable source wiring gates only; never represented as Swift/native execution."""
from pathlib import Path
import json
import unittest

ROOT = Path(__file__).resolve().parents[2]
CORE = ROOT / 'Sources/ClavuneCore'
APP = ROOT / 'Sources/ClavuneApp'

class RecordingLimitContracts(unittest.TestCase):
    def test_hard_backend_and_policy_caps_remain(self):
        policy = json.loads((CORE / 'Resources/resource-policy.json').read_text())
        self.assertEqual(policy['sessionLimitSeconds'], 120)
        self.assertEqual(policy['sampleRate'], 16000)
        self.assertIn('(1...120).contains(value.sessionLimitSeconds)', (CORE / 'Policy.swift').read_text())
        bridge = (ROOT / 'Sources/NativeBridge/WhisperBridge.cpp').read_text()
        self.assertIn('16000 * 120', bridge)

    def test_input_boundary_and_independent_count_cap_precede_conversion(self):
        source = (CORE / 'LiveCaptureBuffer.swift').read_text()
        self.assertIn('deadlineSeconds = startSeconds + Double(policy.sessionLimitSeconds)', source)
        self.assertIn('maxNativeFrames = Int((rate * Double(policy.sessionLimitSeconds)).rounded(.down))', source)
        self.assertLess(source.index('try endpoint.accept('), source.index('try converter.append('))
        self.assertIn('min(beforeEndpoint, maxNativeFrames - acceptedNativeFrames)', source)
        self.assertIn('try endpoint.requireUnprocessedCutoff(seconds)', source)
        self.assertIn('throw DictationError.endpointUncertain', source)

    def test_strict_converter_is_default_and_live_prefix_is_explicit(self):
        source = (CORE / 'AudioConversion.swift').read_text()
        self.assertIn('permitsBoundedPrefix: false', source)
        self.assertIn('guard permitsBoundedPrefix || count + n <= capacity', source)
        self.assertLess(source.index('for i in 0..<n where !src[i].isFinite'), source.index('let retained = min(n, capacity - count)'))
        self.assertNotIn('permitsBoundedPrefix: true', (CORE / 'AudioFileImporter.swift').read_text())

    def test_capture_closes_before_flush_and_explicit_limit_handoff(self):
        source = (CORE / 'CaptureService.swift').read_text()
        body = source.split('    private func complete(_ buffer:', 1)[1].split('    func shutdown()', 1)[0]
        for later in ['let pcm = try buffer.finish()', 'try limitHandoff.publish(audio)', 'onLimitReached(CaptureStopRequest']:
            self.assertLess(body.index('shutdown()'), body.index(later))
        self.assertIn('guard ow_ring_losses(ingress.pointer) == 0 else { throw DictationError.overflow }', body)
        self.assertIn('if ow_ring_losses(ingress.pointer) != 0 { throw DictationError.overflow }', source)
        self.assertNotIn('throw DictationError.durationLimit', source)

    def test_tap_path_still_only_pushes_ingress_metadata(self):
        source = (CORE / 'CaptureService.swift').read_text()
        tap = source.split('input.installTap(', 1)[1].split('configurationObserver =', 1)[0]
        self.assertIn('ow_ring_push_buffer', tap)
        for term in ['onLimitReached', 'converter', 'Task {', '.async', 'NSLock', 'append(', 'write(']:
            self.assertNotIn(term, tap)

    def test_handoff_has_single_consumption_cancel_and_early_cutoff_guards(self):
        source = (CORE / 'LiveCaptureBuffer.swift').read_text().split('struct CaptureLimitHandoff', 1)[1]
        self.assertIn('guard !terminal, audio == nil', source)
        self.assertIn('audio = nil; terminal = true', source)
        self.assertIn('guard cutoffHostTime >= value.stopHostTime', source)
        self.assertIn('mutating func cancel() { audio = nil; terminal = true }', source)

    def test_coordinator_reuses_stop_path_and_guards_stale_callbacks(self):
        source = (APP / 'AppCoordinator.swift').read_text()
        body = source.split('    private func captureReachedLimit(', 1)[1].split('    private func stop(', 1)[0]
        self.assertIn('session.id == request.session, !quitRequested, !closePending', body)
        self.assertIn('[.preparing, .recording].contains(session.phase)', body)
        self.assertIn('if !startCompleted || operationPending', body)
        self.assertIn('pendingLimitRequest = request; firstSamplePending = true', body)
        self.assertIn('stop(request)', body)
        self.assertEqual(source.count('let audio = try await capture.stop(request)'), 1)
        self.assertIn('pendingLimitRequest = nil', source)
        self.assertIn('audio.completionReason == .sessionLimit', source)

    def test_native_cases_cover_boundary_races_and_genuine_error(self):
        core = (ROOT / 'Tests/ClavuneCoreTests/LiveCaptureLimitTests.swift').read_text()
        coordinator = (ROOT / 'Tests/ClavuneCoreTests/RecordingLimitCoordinatorTests.swift').read_text()
        for name in ['testExactBoundaryFinishesAtCap', 'testStraddlingBlockExcludesPostDeadlineSignal',
                     'testResamplingAtSupportedRatesNeverExceedsOutputOrNativeCap',
                     'testFullProduction120SecondCapIsUnchanged', 'testDelayedManualCutoffAndGapAtLimitStillFail',
                     'testCancellationBeforeOrAfterPublicationCannotResurrectPCM']:
            self.assertIn(name, core)
        for name in ['testAutomaticLimitClosesOnce', 'testLimitWithoutFirstSampleCallback',
                     'testDuplicateLimitAndLateCallbacks', 'testCancelWinsWhileLimitDecodeIsPending',
                     'testCancelBeforeQueuedLimitDelivery', 'testGenuineOverflowRemainsFailure',
                     'testOldLimitCallbackCannotStopNewSession']:
            self.assertIn(name, coordinator)
