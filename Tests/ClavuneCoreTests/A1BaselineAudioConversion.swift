// Test-only baseline oracle, copied from the frozen WO4+C2 AudioConversion class.
// Original file SHA-256: c9a506f293fc932b3d7d8aff79f82d09c0dd79c928e9286a3304da59e7eb0a2a
// Only the class identifier/visibility and testable import differ. Do not optimize this oracle.
import AVFAudio
import Foundation
@testable import ClavuneCore

/// One instance owns one continuous native-rate mono stream.
/// Reusable buffers and AVAudioConverter are used only on the non-realtime worker.
final class A1BaselineAudioConversion {
    private let converter: AVAudioConverter
    private let input: AVAudioPCMBuffer
    private let output: AVAudioPCMBuffer
    private let store: UnsafeMutablePointer<Float>
    private let capacity: Int
    public private(set) var count = 0
    private var ended = false
    public let sourceRate: Double

    public init(sourceRate: Double, policy: ResourcePolicy) throws {
        guard sourceRate.isFinite, (8000...192000).contains(sourceRate),
              let src = AVAudioFormat(standardFormatWithSampleRate: sourceRate, channels: 1),
              let dst = AVAudioFormat(standardFormatWithSampleRate: Double(policy.sampleRate), channels: 1),
              let c = AVAudioConverter(from: src, to: dst),
              let i = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: AVAudioFrameCount(policy.maxNativeBlockFrames)),
              let o = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: 8192)
        else { throw DictationError.unsupportedFormat }
        self.sourceRate = sourceRate; converter = c; input = i; output = o
        capacity = policy.maxSamples
        store = .allocate(capacity: capacity)
        store.initialize(repeating: 0, count: capacity)
    }
    deinit { store.deinitialize(count: capacity); store.deallocate() }

    public func append(_ frames: UnsafeBufferPointer<Float>) throws {
        guard !ended, frames.count <= Int(input.frameCapacity), frames.allSatisfy(\.isFinite),
              let dest = input.floatChannelData?[0] else { throw DictationError.unsupportedFormat }
        // The input provider honors requested packet counts and advances once.
        var cursor = 0
        var iterations = 0
        while true {
            iterations += 1
            guard iterations <= 128 else { throw DictationError.audioUnavailable }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { requested, state in
                guard cursor < frames.count else {
                    state.pointee = .noDataNow; return nil
                }
                let amount = min(Int(requested), frames.count - cursor, Int(self.input.frameCapacity))
                guard amount > 0, let base = frames.baseAddress else {
                    state.pointee = .noDataNow; return nil
                }
                dest.update(from: base + cursor, count: amount)
                self.input.frameLength = AVAudioFrameCount(amount)
                cursor += amount; state.pointee = .haveData
                return self.input
            }
            try consumeOutput()
            if error != nil || status == .error { throw DictationError.audioUnavailable }
            if status == .inputRanDry {
                guard cursor == frames.count else { throw DictationError.discontinuity }
                return
            }
            if status == .endOfStream { throw DictationError.discontinuity }
        }
    }
    public func finish() throws -> SessionPCM {
        guard !ended else { throw DictationError.discontinuity }
        ended = true
        var finished = false
        for _ in 0..<128 {
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                state.pointee = .endOfStream; return nil
            }
            try consumeOutput()
            if error != nil || status == .error { throw DictationError.audioUnavailable }
            if status == .endOfStream { finished = true; break }
        }
        guard finished else { throw DictationError.audioUnavailable }
        guard count > 0 else { throw DictationError.noAudio }
        // A single bounded handoff copy. No repeated full-session snapshots.
        return SessionPCM(samples: Array(UnsafeBufferPointer(start: store, count: count)))
    }
    private func consumeOutput() throws {
        let n = Int(output.frameLength)
        guard count + n <= capacity else { throw DictationError.durationLimit }
        if n > 0, let src = output.floatChannelData?[0] {
            for i in 0..<n where !src[i].isFinite { throw DictationError.unsupportedFormat }
            store.advanced(by: count).update(from: src, count: n); count += n
        }
        output.frameLength = 0
    }
}
