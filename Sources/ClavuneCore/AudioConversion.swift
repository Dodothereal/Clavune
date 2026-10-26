import AVFAudio
import Foundation

/// One instance owns one continuous native-rate mono stream.
/// Reusable buffers and AVAudioConverter are used only on the non-realtime worker.
public final class AudioConversion {
    private let converter: AVAudioConverter
    private let input: AVAudioPCMBuffer
    private let output: AVAudioPCMBuffer
    private let store: UnsafeMutablePointer<Float>
    private let capacity: Int
    private let permitsBoundedPrefix: Bool
    public private(set) var count = 0
    private var ended = false
    public let sourceRate: Double

    public convenience init(sourceRate: Double, policy: ResourcePolicy) throws {
        try self.init(sourceRate: sourceRate, policy: policy, permitsBoundedPrefix: false)
    }
    /// Live capture alone bounds native input first, then retains at most maxSamples.
    /// File import and other callers remain strict: excess output is an error.
    init(sourceRate: Double, policy: ResourcePolicy, permitsBoundedPrefix: Bool) throws {
        guard sourceRate.isFinite, (8000...192000).contains(sourceRate),
              let src = AVAudioFormat(standardFormatWithSampleRate: sourceRate, channels: 1),
              let dst = AVAudioFormat(standardFormatWithSampleRate: Double(policy.sampleRate), channels: 1),
              let c = AVAudioConverter(from: src, to: dst),
              let i = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: AVAudioFrameCount(policy.maxNativeBlockFrames)),
              let o = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: 8192)
        else { throw DictationError.unsupportedFormat }
        self.sourceRate = sourceRate; converter = c; input = i; output = o
        self.permitsBoundedPrefix = permitsBoundedPrefix
        capacity = policy.maxSamples
        store = .allocate(capacity: capacity)
        store.initialize(repeating: 0, count: capacity)
    }
    deinit { store.deinitialize(count: capacity); store.deallocate() }

    @discardableResult
    public func append(_ frames: UnsafeBufferPointer<Float>) throws -> Float {
        guard !ended, frames.count <= Int(input.frameCapacity),
              let dest = input.floatChannelData?[0] else { throw DictationError.unsupportedFormat }
        // Validate the entire accepted native block before changing converter state.
        // Return its raw peak only after conversion accepts the complete input.
        var peak: Float = 0
        for value in frames {
            guard value.isFinite else { throw DictationError.unsupportedFormat }
            peak = max(peak, abs(value))
        }
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
                return peak
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
        guard permitsBoundedPrefix || count + n <= capacity else { throw DictationError.durationLimit }
        if n > 0 {
            guard let src = output.floatChannelData?[0] else { throw DictationError.unsupportedFormat }
            // Validate even converter tail samples outside the retained prefix.
            for i in 0..<n where !src[i].isFinite { throw DictationError.unsupportedFormat }
            let retained = min(n, capacity - count)
            store.advanced(by: count).update(from: src, count: retained); count += retained
        }
        output.frameLength = 0
    }
}

public struct SessionPCM: Sendable {
    public let samples: [Float]
    public let sampleRate = 16000
    public init(samples: [Float]) { self.samples = samples }
}

public struct AudioEndpoint: Sendable {
    public private(set) var expectedSample: Int64?
    public private(set) var coveredHostSeconds: Double?
    public private(set) var firstHostSeconds: Double?
    public init() {}
    /// A queued stop cannot retroactively remove already-converted native input.
    /// Reject this race before inference instead of leaking post-cutoff signal through filter state.
    public func requireUnprocessedCutoff(_ cutoff: Double) throws {
        guard cutoff.isFinite else { throw DictationError.endpointUncertain }
        if let coveredHostSeconds, coveredHostSeconds > cutoff + 0.000000001 {
            throw DictationError.endpointUncertain
        }
    }
    /// Source channel was selected deliberately before ingress. No averaging of unrelated channels.
    public mutating func accept(frames: Int, sampleTime: Int64?, hostSeconds: Double?,
                                rate: Double, cutoff: Double?) throws -> Int {
        guard frames > 0, rate.isFinite, rate > 0,
              let sample = sampleTime, let host = hostSeconds, host.isFinite
        else { throw DictationError.discontinuity }
        if let expectedSample, sample != expectedSample { throw DictationError.discontinuity }
        if let coveredHostSeconds, abs(host - coveredHostSeconds) > max(0.002, 2 / rate) {
            throw DictationError.discontinuity
        }
        expectedSample = sample + Int64(frames)
        firstHostSeconds = firstHostSeconds ?? host
        coveredHostSeconds = host + Double(frames) / rate
        guard let cutoff else { return frames }
        // The sample interval containing cutoff is included; later samples are excluded.
        return min(frames, max(0, Int(ceil((cutoff - host) * rate - 0.000001))))
    }
    public func covers(_ cutoff: Double) -> Bool {
        guard let coveredHostSeconds, let firstHostSeconds else { return false }
        return firstHostSeconds <= cutoff && coveredHostSeconds >= cutoff
    }
}
