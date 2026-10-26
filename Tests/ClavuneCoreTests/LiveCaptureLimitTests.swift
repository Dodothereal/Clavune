import AVFAudio
import XCTest
@testable import ClavuneCore

/// Synthetic PCM only; these execute the actual live-buffer/converter and handoff.
final class LiveCaptureLimitTests: XCTestCase {
    private func policy(seconds: Int = 1) throws -> ResourcePolicy {
        let bundled = try ResourcePolicy.bundled()
        return ResourcePolicy(schemaVersion: bundled.schemaVersion, sampleRate: bundled.sampleRate,
            sessionLimitSeconds: seconds, ringSlots: bundled.ringSlots,
            maxNativeBlockFrames: bundled.maxNativeBlockFrames,
            pumpIntervalMilliseconds: bundled.pumpIntervalMilliseconds,
            firstBufferTimeoutSeconds: bundled.firstBufferTimeoutSeconds,
            stopDrainTimeoutSeconds: bundled.stopDrainTimeoutSeconds, maxInputChannels: bundled.maxInputChannels,
            inferenceThreads: bundled.inferenceThreads, activeInferenceJobs: 1, previewEnabled: false)
    }
    private func append(_ values: [Float], to buffer: LiveCaptureBuffer, sample: Int, host: Double) throws {
        try values.withUnsafeBufferPointer { _ = try buffer.append($0, sampleTime: Int64(sample), hostSeconds: host) }
    }
    func testExactBoundaryFinishesAtCapAndRejectsFurtherInputOrDuplicateFinish() throws {
        let policy = try policy()
        let buffer = try LiveCaptureBuffer(rate: 16000, policy: policy, startSeconds: 10)
        for offset in stride(from: 0, to: 16000, by: 1000) {
            try append([Float](repeating: 0.25, count: 1000), to: buffer, sample: offset, host: 10 + Double(offset) / 16000)
        }
        XCTAssertEqual(buffer.acceptedNativeFrames, 16000)
        XCTAssertTrue(try buffer.shouldFinish(now: 11))
        XCTAssertEqual(buffer.completionReason, .sessionLimit)
        let pcm = try buffer.finish()
        XCTAssertEqual(pcm.samples.count, policy.maxSamples)
        XCTAssertThrowsError(try append([0.9], to: buffer, sample: 16000, host: 11))
        XCTAssertThrowsError(try buffer.finish())
    }
    func testStraddlingBlockExcludesPostDeadlineSignalAndDoesNotWaitForAnotherCallback() throws {
        let buffer = try LiveCaptureBuffer(rate: 16000, policy: policy(), startSeconds: 10)
        for offset in stride(from: 0, to: 15000, by: 1000) {
            try append([Float](repeating: 0, count: 1000), to: buffer, sample: offset, host: 10 + Double(offset) / 16000)
        }
        try append([Float](repeating: 0, count: 1000) + [Float](repeating: 0.9, count: 1000),
            to: buffer, sample: 15000, host: 10.9375)
        XCTAssertTrue(try buffer.shouldFinish(now: 11.1))
        let pcm = try buffer.finish()
        XCTAssertEqual(pcm.samples.count, 16000)
        XCTAssertTrue(pcm.samples.allSatisfy { $0 == 0 })
    }
    func testResamplingAtSupportedRatesNeverExceedsOutputOrNativeCap() throws {
        let policy = try policy()
        for rate in [8000.0, 16000, 24000, 44100, 48000, 96000, 192000] {
            let buffer = try LiveCaptureBuffer(rate: rate, policy: policy, startSeconds: 10)
            var offset = 0
            while !buffer.endIsCovered {
                let amount = min(1000, Int(rate) - offset + 7)
                try append([Float](repeating: 0, count: amount), to: buffer, sample: offset, host: 10 + Double(offset) / rate)
                offset += amount
            }
            let pcm = try buffer.finish()
            XCTAssertLessThanOrEqual(buffer.acceptedNativeFrames, Int(rate))
            XCTAssertLessThanOrEqual(pcm.samples.count, policy.maxSamples)
            XCTAssertGreaterThanOrEqual(pcm.samples.count, policy.maxSamples - 1)
            XCTAssertEqual(buffer.completionReason, .sessionLimit)
        }
    }
    func testDelayedFirstInputPreservesNonzeroResamplerFlushAtExactLimit() throws {
        for rate in [44100.0, 48000.0] {
            try assertDelayedNonzeroTail(rate: rate, straddles: false)
        }
    }
    func testDelayedFirstInputClipsSentinelBeforeResamplerAndPreservesNonzeroFlush() throws {
        for rate in [44100.0, 48000.0] {
            try assertDelayedNonzeroTail(rate: rate, straddles: true)
        }
    }
    private func assertDelayedNonzeroTail(rate: Double, straddles: Bool,
                                         file: StaticString = #filePath, line: UInt = #line) throws {
        let policy = try policy()
        // Preparation begins at zero, but input starts 250 ms later. The straddling
        // case also offsets by a fractional frame: the interval containing cutoff
        // is accepted, while the next interval and its sentinel must be excluded.
        let firstHost = 0.25 + (straddles ? 0.37 / rate : 0)
        let acceptedTotal = Int(rate * 0.75)
        let live = try LiveCaptureBuffer(rate: rate, policy: policy, startSeconds: 0)
        let negativeSentinel = try LiveCaptureBuffer(rate: rate, policy: policy, startSeconds: 0)
        // Default STRICT converter, not a second LiveCaptureBuffer/AudioEndpoint:
        // its input is independently clipped using the fixture's known frame count.
        let reference = try AudioConversion(sourceRate: rate, policy: policy)
        var offset = 0
        while offset < acceptedTotal {
            let amount = min(997, acceptedTotal - offset)
            let isLast = offset + amount == acceptedTotal
            let signal = (offset..<(offset + amount)).map { frame -> Float in
                // Last 20 ms stay strongly nonzero, including the final native frame.
                // This catches a lost valid converter tail that silence cannot expose.
                guard frame >= acceptedTotal - Int(rate / 50) else { return 0 }
                return Float(0.3 + 0.1 * sin(2 * Double.pi * 731 * Double(frame) / rate))
            }
            let host = isLast && !straddles
                ? 1 - Double(amount) / rate : firstHost + Double(offset) / rate
            let sentinelCount = isLast && straddles ? 53 : 0
            try append(signal + [Float](repeating: 0.95, count: sentinelCount),
                to: live, sample: offset, host: host)
            try append(signal + [Float](repeating: -0.95, count: sentinelCount),
                to: negativeSentinel, sample: offset, host: host)
            try signal.withUnsafeBufferPointer { _ = try reference.append($0) }
            offset += amount
        }
        XCTAssertEqual(live.deadlineSeconds, 1, file: file, line: line)
        XCTAssertEqual(live.endSeconds, 1, file: file, line: line)
        XCTAssertEqual(live.acceptedNativeFrames, acceptedTotal, file: file, line: line)
        XCTAssertEqual(negativeSentinel.acceptedNativeFrames, acceptedTotal, file: file, line: line)
        XCTAssertLessThan(live.acceptedNativeFrames, live.maxNativeFrames, file: file, line: line)
        XCTAssertTrue(try live.shouldFinish(now: 1), file: file, line: line)
        XCTAssertEqual(live.completionReason, .sessionLimit, file: file, line: line)
        let beforeFlush = reference.count
        XCTAssertEqual(live.count, beforeFlush, file: file, line: line)
        let expected = try reference.finish().samples
        let actual = try live.finish().samples
        let opposite = try negativeSentinel.finish().samples
        // Do not let an empty/all-silent flush make the tail comparison vacuous.
        XCTAssertGreaterThan(expected.count, beforeFlush, file: file, line: line)
        XCTAssertTrue(expected.dropFirst(beforeFlush).contains { abs($0) > 0.01 }, file: file, line: line)
        XCTAssertGreaterThanOrEqual(expected.count, 11_999, file: file, line: line)
        XCTAssertLessThanOrEqual(expected.count, 12_001, file: file, line: line)
        XCTAssertLessThan(actual.count, policy.maxSamples, file: file, line: line)
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        XCTAssertEqual(opposite.count, expected.count, file: file, line: line)
        // Whole-buffer equality includes every emitted flush sample. Changing the
        // excluded sentinel's sign cannot affect even one retained output sample.
        for index in expected.indices {
            guard index < actual.count, index < opposite.count else { break }
            XCTAssertTrue(actual[index].isFinite && opposite[index].isFinite, file: file, line: line)
            XCTAssertEqual(actual[index], expected[index], accuracy: 0.000001, "sample \(index), rate \(rate)", file: file, line: line)
            XCTAssertEqual(opposite[index], expected[index], accuracy: 0.000001, "opposite sentinel sample \(index), rate \(rate)", file: file, line: line)
        }
    }
    func testFullProduction120SecondCapIsUnchanged() throws {
        let policy = try ResourcePolicy.bundled()
        XCTAssertEqual(policy.sessionLimitSeconds, 120)
        let buffer = try LiveCaptureBuffer(rate: 16000, policy: policy, startSeconds: 10)
        var offset = 0
        while offset < policy.maxSamples {
            let amount = min(4096, policy.maxSamples - offset)
            try append([Float](repeating: 0, count: amount), to: buffer, sample: offset, host: 10 + Double(offset) / 16000)
            offset += amount
        }
        XCTAssertEqual(try buffer.finish().samples.count, 1_920_000)
        XCTAssertEqual(buffer.endSeconds, 130)
    }
    func testEarlierManualStopStillOwnsCutoffAndReason() throws {
        let buffer = try LiveCaptureBuffer(rate: 16000, policy: policy(), startSeconds: 10)
        try buffer.requestStop(at: 10.025)
        try append([Float](repeating: 0, count: 400) + [Float](repeating: 0.9, count: 400),
            to: buffer, sample: 0, host: 10)
        XCTAssertEqual(buffer.completionReason, .requestedStop)
        XCTAssertEqual(try buffer.finish().samples.count, 400)
    }
    func testDelayedManualCutoffAndGapAtLimitStillFail() throws {
        let buffer = try LiveCaptureBuffer(rate: 16000, policy: policy(), startSeconds: 10)
        try append([Float](repeating: 0, count: 1000), to: buffer, sample: 0, host: 10)
        XCTAssertThrowsError(try buffer.requestStop(at: 10.025)) {
            XCTAssertEqual($0 as? DictationError, .endpointUncertain)
        }
        XCTAssertThrowsError(try append([Float](repeating: 0, count: 1000), to: buffer, sample: 1001, host: 10.95)) {
            XCTAssertEqual($0 as? DictationError, .discontinuity)
        }
        XCTAssertThrowsError(try buffer.shouldFinish(now: 11.5)) {
            XCTAssertEqual($0 as? DictationError, .endpointUncertain)
        }
    }
    func testNonfiniteAcceptedSampleIsNotRecoveredAsLimit() throws {
        let buffer = try LiveCaptureBuffer(rate: 16000, policy: policy(), startSeconds: 10)
        XCTAssertThrowsError(try append([0, .nan], to: buffer, sample: 0, host: 10)) {
            XCTAssertEqual($0 as? DictationError, .unsupportedFormat)
        }
    }
    func testOrdinaryConverterStillRejectsExcessOutput() throws {
        let conversion = try AudioConversion(sourceRate: 16000, policy: policy())
        XCTAssertThrowsError(try {
            for _ in 0..<17 { try [Float](repeating: 0, count: 1000).withUnsafeBufferPointer { try conversion.append($0) } }
            _ = try conversion.finish()
        }()) { XCTAssertEqual($0 as? DictationError, .durationLimit) }
    }
    private var audio: CapturedAudio {
        CapturedAudio(pcm: SessionPCM(samples: [0, 0.2]), firstHostTime: 1,
            stopHostTime: 100, closedHostTime: 101, nativeRate: 16000, completionReason: .sessionLimit)
    }
    func testLimitHandoffConsumesOnceAndRejectsEarlierRequestedStop() throws {
        var handoff = CaptureLimitHandoff()
        try handoff.publish(audio)
        XCTAssertThrowsError(try handoff.take(cutoffHostTime: 99)) {
            XCTAssertEqual($0 as? DictationError, .endpointUncertain)
        }
        XCTAssertFalse(handoff.isPending)
        XCTAssertThrowsError(try handoff.take(cutoffHostTime: 100))
        XCTAssertThrowsError(try handoff.publish(audio))
        var successful = CaptureLimitHandoff()
        try successful.publish(audio)
        XCTAssertEqual(try successful.take(cutoffHostTime: 100).pcm.samples, [0, 0.2])
        XCTAssertThrowsError(try successful.take(cutoffHostTime: 100))
    }
    func testCancellationBeforeOrAfterPublicationCannotResurrectPCM() throws {
        var before = CaptureLimitHandoff(); before.cancel()
        XCTAssertThrowsError(try before.publish(audio))
        var after = CaptureLimitHandoff(); try after.publish(audio); after.cancel()
        XCTAssertFalse(after.isPending)
        XCTAssertThrowsError(try after.take(cutoffHostTime: 100))
        XCTAssertThrowsError(try after.publish(audio))
    }
}
