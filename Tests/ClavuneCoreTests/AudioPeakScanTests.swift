import Foundation
import XCTest
@testable import ClavuneCore

/// Synthetic actual-AVAudioConverter tests. No engine, microphone, model or timing claims.
/// The baseline oracle retains the exact pre-A1 conversion and storage algorithm.
final class AudioPeakScanTests: XCTestCase {
    private func policy(seconds: Int = 1) throws -> ResourcePolicy {
        let original = try ResourcePolicy.bundled()
        return ResourcePolicy(schemaVersion: original.schemaVersion, sampleRate: original.sampleRate,
            sessionLimitSeconds: seconds, ringSlots: original.ringSlots,
            maxNativeBlockFrames: original.maxNativeBlockFrames,
            pumpIntervalMilliseconds: original.pumpIntervalMilliseconds,
            firstBufferTimeoutSeconds: original.firstBufferTimeoutSeconds,
            stopDrainTimeoutSeconds: original.stopDrainTimeoutSeconds,
            maxInputChannels: original.maxInputChannels, inferenceThreads: original.inferenceThreads,
            activeInferenceJobs: original.activeInferenceJobs, previewEnabled: original.previewEnabled)
    }

    private func signal(_ count: Int) -> [Float] {
        (0..<count).map { index in
            Float(sin(Double(index) * 0.071) * 0.3 + cos(Double(index) * 0.013) * 0.1)
        }
    }

    private func checkExactPCM(_ candidate: AudioConversion, _ baseline: A1BaselineAudioConversion,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let actual = try candidate.finish().samples
        let expected = try baseline.finish().samples
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        XCTAssertEqual(actual.map(\.bitPattern), expected.map(\.bitPattern),
                       "Scan-only change altered PCM bits", file: file, line: line)
    }

    func testFiniteRawPeakIncludesNegativeSubnormalAndAboveOneValues() throws {
        let cases: [([Float], Float)] = [
            ([0, -0.0], 0),
            ([Float.leastNonzeroMagnitude], Float.leastNonzeroMagnitude),
            ([-Float.leastNonzeroMagnitude], Float.leastNonzeroMagnitude),
            ([0.125, -0.875, 0.5], 0.875),
            ([-2.25, 1.25, -0.25], 2.25)
        ]
        for (frames, expected) in cases {
            let converter = try AudioConversion(sourceRate: 16000, policy: policy())
            let actual = try frames.withUnsafeBufferPointer { try converter.append($0) }
            XCTAssertEqual(actual.bitPattern, expected.bitPattern)
        }
    }

    func testRawPeakIsNotClampedButMeterRemainsClamped() throws {
        let converter = try AudioConversion(sourceRate: 16000, policy: policy())
        let peak = try [Float(-1.75), 0.25].withUnsafeBufferPointer { try converter.append($0) }
        XCTAssertEqual(peak, 1.75)
        var meter = CapturePeakAccumulator()
        meter.observe(peak)
        XCTAssertEqual(meter.take(), 1)
        XCTAssertEqual(meter.take(), 0)
    }

    func testNonfiniteAtEveryPositionRejectsBeforeObservableConverterMutation() throws {
        for invalid in [Float.nan, Float.infinity, -Float.infinity] {
            for position in [0, 158, 316] {
                let candidate = try AudioConversion(sourceRate: 44100, policy: policy())
                let baseline = try A1BaselineAudioConversion(sourceRate: 44100, policy: policy())
                // Establish continuous converter state before rejecting an invalid middle block.
                let prefix = signal(317)
                _ = try prefix.withUnsafeBufferPointer { try candidate.append($0) }
                try prefix.withUnsafeBufferPointer { try baseline.append($0) }
                let before = candidate.count
                var frames = signal(317)
                frames[position] = invalid
                XCTAssertThrowsError(try frames.withUnsafeBufferPointer { try candidate.append($0) }) {
                    XCTAssertEqual($0 as? DictationError, .unsupportedFormat)
                }
                XCTAssertEqual(candidate.count, before)
                let suffix = signal(2048)
                _ = try suffix.withUnsafeBufferPointer { try candidate.append($0) }
                try suffix.withUnsafeBufferPointer { try baseline.append($0) }
                try checkExactPCM(candidate, baseline)
            }
        }
    }

    func testOversizeRejectsWithoutStateChangeAndMaximumBlockIsAccepted() throws {
        let p = try policy()
        let candidate = try AudioConversion(sourceRate: 16000, policy: p)
        let baseline = try A1BaselineAudioConversion(sourceRate: 16000, policy: p)
        let oversized = [Float](repeating: 0.9, count: p.maxNativeBlockFrames + 1)
        XCTAssertThrowsError(try oversized.withUnsafeBufferPointer { try candidate.append($0) }) {
            XCTAssertEqual($0 as? DictationError, .unsupportedFormat)
        }
        XCTAssertEqual(candidate.count, 0)
        var maximum = signal(p.maxNativeBlockFrames)
        maximum[maximum.count - 1] = -0.95
        let peak = try maximum.withUnsafeBufferPointer { try candidate.append($0) }
        XCTAssertEqual(peak, 0.95)
        try maximum.withUnsafeBufferPointer { try baseline.append($0) }
        try checkExactPCM(candidate, baseline)
    }

    func testEmptyDirectAppendReturnsPositiveZeroWithoutChangingPCM() throws {
        let candidate = try AudioConversion(sourceRate: 48000, policy: policy())
        let baseline = try A1BaselineAudioConversion(sourceRate: 48000, policy: policy())
        let empty = UnsafeBufferPointer<Float>(start: nil, count: 0)
        XCTAssertEqual(try candidate.append(empty).bitPattern, Float(0).bitPattern)
        try baseline.append(empty)
        let frames = signal(4096)
        _ = try frames.withUnsafeBufferPointer { try candidate.append($0) }
        try frames.withUnsafeBufferPointer { try baseline.append($0) }
        XCTAssertEqual(try candidate.append(empty).bitPattern, Float(0).bitPattern)
        try baseline.append(empty)
        try checkExactPCM(candidate, baseline)
    }

    func testEmptyFinishHasSameFailureAsUnchangedBaseline() throws {
        let candidate = try AudioConversion(sourceRate: 16000, policy: policy())
        let baseline = try A1BaselineAudioConversion(sourceRate: 16000, policy: policy())
        var actual: DictationError?
        var expected: DictationError?
        do { _ = try candidate.finish(); XCTFail("Empty capture unexpectedly succeeded") }
        catch { actual = error as? DictationError }
        do { _ = try baseline.finish(); XCTFail("Empty baseline unexpectedly succeeded") }
        catch { expected = error as? DictationError }
        XCTAssertNotNil(expected)
        XCTAssertEqual(actual, expected)
    }

    func testExactPCMMatchesFrozenBaselineAtNativeRateBoundariesAndChunkSequences() throws {
        for rate in [8000.0, 16000, 24000, 44100, 48000, 96000, 192000] {
            for quantum in [317, 4096] {
                let p = try policy(seconds: 2)
                let candidate = try AudioConversion(sourceRate: rate, policy: p)
                let baseline = try A1BaselineAudioConversion(sourceRate: rate, policy: p)
                var frames = signal(5003)
                frames[0] = -0.0
                frames[1] = Float.leastNonzeroMagnitude
                frames[2] = -Float.leastNonzeroMagnitude
                frames[frames.count - 1] = -0.75
                try frames.withUnsafeBufferPointer { input in
                    var offset = 0
                    while offset < input.count {
                        let count = min(quantum, input.count - offset)
                        let block = UnsafeBufferPointer(start: input.baseAddress! + offset, count: count)
                        let expected = block.reduce(Float(0)) { max($0, abs($1)) }
                        XCTAssertEqual(try candidate.append(block).bitPattern, expected.bitPattern)
                        try baseline.append(block)
                        offset += count
                    }
                }
                try checkExactPCM(candidate, baseline)
            }
        }
    }

    func testMultipleBlocksAndEmptyTicksRetainEarlierPeakUntilPublication() throws {
        let converter = try AudioConversion(sourceRate: 16000, policy: policy())
        var meter = CapturePeakAccumulator()
        let ticks: [[Float]] = [[0.1], [-0.9], [], [0.2], [], [], []]
        for values in ticks {
            var level: Float = 0
            if !values.isEmpty {
                let peak = try values.withUnsafeBufferPointer { try converter.append($0) }
                level = max(level, peak)
            }
            meter.observe(level)
        }
        XCTAssertEqual(meter.take(), 0.9)
        meter.observe(0)
        XCTAssertEqual(meter.take(), 0)
    }

    func testConversionFailureAfterFiniteValidationDoesNotReturnPeak() throws {
        let p = try policy()
        let converter = try AudioConversion(sourceRate: 16000, policy: p)
        let quiet = [Float](repeating: 0.25, count: p.maxNativeBlockFrames)
        for _ in 0..<3 {
            XCTAssertEqual(try quiet.withUnsafeBufferPointer { try converter.append($0) }, 0.25)
        }
        let louder = [Float](repeating: -0.95, count: p.maxNativeBlockFrames)
        var sawLimit = false
        for _ in 0..<3 {
            var returnedPeak: Float?
            do {
                returnedPeak = try louder.withUnsafeBufferPointer { try converter.append($0) }
            } catch {
                XCTAssertEqual(error as? DictationError, .durationLimit)
                XCTAssertNil(returnedPeak, "A failed append must not return a successful peak")
                sawLimit = true
                break
            }
        }
        XCTAssertTrue(sawLimit, "Synthetic finite input must cross the unchanged one-second capacity")
    }

    func testAppendAfterFinishStillRejectsEmptyAndNonemptyInput() throws {
        let converter = try AudioConversion(sourceRate: 16000, policy: policy())
        _ = try signal(317).withUnsafeBufferPointer { try converter.append($0) }
        _ = try converter.finish()
        let afterFinish: [[Float]] = [[], [0.2]]
        for values in afterFinish {
            XCTAssertThrowsError(try values.withUnsafeBufferPointer { try converter.append($0) }) {
                XCTAssertEqual($0 as? DictationError, .unsupportedFormat)
            }
        }
        XCTAssertThrowsError(try converter.finish()) {
            XCTAssertEqual($0 as? DictationError, .discontinuity)
        }
    }

    func testProductionPumpWiringConsumesSuccessfulReturnWithoutRescanningSource() throws {
        // Source-bound wiring assertion, not a hardware CaptureSession execution claim.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/ClavuneCore/CaptureService.swift"),
                                encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "    private func pump() {"))
        let tail = source[start.lowerBound...]
        let end = try XCTUnwrap(tail.range(of: "    private func complete(_ buffer:"))
        let pump = String(tail[..<end.lowerBound])
        XCTAssertTrue(pump.contains("let peak = try buffer.append(UnsafeBufferPointer(start: scratch, count: Int(block.frames)),"))
        XCTAssertTrue(pump.contains("sampleTime: block.sample_valid == 1 ? block.sample_time : nil,"))
        XCTAssertTrue(pump.contains("hostSeconds: block.host_valid == 1 ? AVAudioTime.seconds(forHostTime: block.host_time) : nil)\n                level = max(level, peak)"))
        XCTAssertFalse(pump.contains("for i in"))
        XCTAssertFalse(pump.contains("abs(scratch"))
        XCTAssertTrue(pump.contains("if buffer.acceptedNativeFrames > 0, !firstDelivered { firstDelivered = true; onFirst() }"))
        XCTAssertTrue(pump.contains("meterPeak.observe(level)"))
        XCTAssertTrue(pump.contains("if now - lastProgress >= 0.1"))
        XCTAssertTrue(pump.contains("onProgress(Double(buffer.count) / Double(policy.sampleRate), meterPeak.take())"))

        // The live prefix wrapper must forward the converter's successful peak;
        // moving clipping out of the pump must not introduce another sample scan.
        let live = try String(contentsOf: root.appendingPathComponent("Sources/ClavuneCore/LiveCaptureBuffer.swift"),
                              encoding: .utf8)
        let append = try XCTUnwrap(live.range(of: "    func append(_ frames:"))
        let liveTail = live[append.lowerBound...]
        let appendEnd = try XCTUnwrap(liveTail.range(of: "    func shouldFinish(now:"))
        let block = String(liveTail[..<appendEnd.lowerBound])
        XCTAssertTrue(block.contains("let peak = try converter.append(UnsafeBufferPointer(rebasing: frames[..<accepted]))\n        acceptedNativeFrames += accepted"))
        XCTAssertTrue(block.contains("return peak"))
        XCTAssertFalse(block.contains("for "))
        XCTAssertFalse(block.contains("abs("))
    }
}
