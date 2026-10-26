import Foundation

/// Non-realtime, single-owner live PCM accumulation. The wall-clock deadline is
/// fixed before engine start; continuous native input and 16-kHz output are also
/// independently capped. The ordinary user endpoint validation remains intact.
final class LiveCaptureBuffer {
    private let converter: AudioConversion
    private var endpoint = AudioEndpoint()
    private let rate: Double
    private let policy: ResourcePolicy
    let deadlineSeconds: Double
    let maxNativeFrames: Int
    private(set) var acceptedNativeFrames = 0
    private var requestedEnd: Double?
    private var capacityEnd: Double?
    private var finished = false
    var count: Int { converter.count }
    var endSeconds: Double { min(requestedEnd ?? deadlineSeconds, capacityEnd ?? deadlineSeconds, deadlineSeconds) }
    var completionReason: CaptureCompletionReason {
        guard capacityEnd == nil, let requestedEnd, requestedEnd < deadlineSeconds else { return .sessionLimit }
        return .requestedStop
    }
    var endIsCovered: Bool { endpoint.covers(endSeconds) }

    init(rate: Double, policy: ResourcePolicy, startSeconds: Double) throws {
        guard startSeconds.isFinite, rate.isFinite, (8000...192000).contains(rate),
              policy.sampleRate == 16000, (1...120).contains(policy.sessionLimitSeconds) else {
            throw DictationError.configuration
        }
        self.rate = rate; self.policy = policy
        deadlineSeconds = startSeconds + Double(policy.sessionLimitSeconds)
        maxNativeFrames = Int((rate * Double(policy.sessionLimitSeconds)).rounded(.down))
        converter = try AudioConversion(sourceRate: rate, policy: policy, permitsBoundedPrefix: true)
    }
    func requestStop(at seconds: Double) throws {
        guard !finished else { throw DictationError.endpointUncertain }
        try endpoint.requireUnprocessedCutoff(seconds)
        requestedEnd = seconds
    }
    @discardableResult
    func append(_ frames: UnsafeBufferPointer<Float>, sampleTime: Int64?, hostSeconds: Double?) throws -> Float {
        guard !finished, !endIsCovered else { throw DictationError.discontinuity }
        // Validate continuity before clipping. Neither a gap nor a corrupt timestamp
        // is reclassified as normal completion merely because it straddles the limit.
        let beforeEndpoint = try endpoint.accept(frames: frames.count, sampleTime: sampleTime,
            hostSeconds: hostSeconds, rate: rate, cutoff: endSeconds)
        guard let hostSeconds else { throw DictationError.discontinuity }
        let accepted = min(beforeEndpoint, maxNativeFrames - acceptedNativeFrames)
        guard accepted > 0 else { return 0 }
        let peak = try converter.append(UnsafeBufferPointer(rebasing: frames[..<accepted]))
        acceptedNativeFrames += accepted
        if acceptedNativeFrames == maxNativeFrames || converter.count == policy.maxSamples {
            capacityEnd = min(deadlineSeconds, hostSeconds + Double(accepted) / rate)
        }
        return peak
    }
    func shouldFinish(now: Double) throws -> Bool {
        if endIsCovered { return true }
        // A stalled producer is still an uncertain endpoint, not recovered audio.
        if now - endSeconds >= policy.stopDrainTimeoutSeconds { throw DictationError.endpointUncertain }
        return false
    }
    func finish() throws -> SessionPCM {
        guard !finished, endIsCovered else { throw DictationError.endpointUncertain }
        finished = true
        return try converter.finish()
    }
}

/// Queue-confined single-consumer handoff after automatic hardware closure.
/// Separate from hardware so cancellation, early cutoff and duplicate consumption
/// can be tested without creating an AVAudioEngine or touching a microphone.
struct CaptureLimitHandoff {
    private var audio: CapturedAudio?
    private var terminal = false
    var isPending: Bool { audio != nil }
    mutating func publish(_ value: CapturedAudio) throws {
        guard !terminal, audio == nil, value.completionReason == .sessionLimit else {
            throw DictationError.discontinuity
        }
        audio = value
    }
    mutating func take(cutoffHostTime: UInt64) throws -> CapturedAudio {
        guard let value = audio, !terminal else { throw DictationError.noAudio }
        audio = nil; terminal = true
        // An earlier user stop cannot authorize audio already captured beyond it.
        guard cutoffHostTime >= value.stopHostTime else { throw DictationError.endpointUncertain }
        return value
    }
    mutating func cancel() { audio = nil; terminal = true }
}
