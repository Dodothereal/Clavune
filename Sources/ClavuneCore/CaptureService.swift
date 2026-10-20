import AVFAudio
import AudioToolbox
import CoreAudio
import Foundation
import NativeBridge

public struct AudioInputDevice: Identifiable, Sendable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
}

public enum AudioDeviceRegistry {
    public static func inputs() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var bytes: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &bytes) == noErr else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(bytes) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &bytes, &devices) == noErr else { return [] }
        return devices.compactMap { id in
            var stream = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var streamBytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &stream, 0, nil, &streamBytes) == noErr, streamBytes > 0,
                  let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name)
        }
    }
    private static func string(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

public struct CapturedAudio: Sendable {
    public let pcm: SessionPCM
    public let firstHostTime: UInt64
    public let stopHostTime: UInt64
    public let closedHostTime: UInt64
    public let nativeRate: Double
}

private final class Ingress: @unchecked Sendable {
    let pointer: OpaquePointer
    init(policy: ResourcePolicy) throws {
        guard let p = ow_ring_create(UInt32(policy.ringSlots), UInt32(policy.maxNativeBlockFrames))
        else { throw DictationError.audioUnavailable }
        pointer = p
    }
    deinit { ow_ring_destroy(pointer) }
}

/// All AVAudioEngine lifecycle work and conversion is serialized on queue.
/// The callback owns only its ingress reference; borrowed framework buffers never escape it.
public final class CaptureService: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.clavune.capture", qos: .userInitiated)
    private var active: CaptureSession?
    public init() {}
    public func start(session: UUID, deviceID: AudioDeviceID?, channel: Int, policy: ResourcePolicy,
                      onFirstSample: @escaping @Sendable () -> Void,
                      onProgress: @escaping @Sendable (Double, Float) -> Void,
                      onFailure: @escaping @Sendable (DictationError) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard self.active == nil else { continuation.resume(throwing: DictationError.busy); return }
                do {
                    let run = try CaptureSession(id: session, queue: self.queue, deviceID: deviceID,
                        channel: channel, policy: policy, onFirst: onFirstSample,
                        onProgress: onProgress, onFailure: onFailure)
                    self.active = run
                    run.onFinished = { [weak owner = self] in
                        if owner?.active?.id == session { owner?.active = nil }
                    }
                    try run.start()
                    continuation.resume()
                } catch {
                    self.active?.shutdown(); self.active = nil
                    continuation.resume(throwing: (error as? DictationError) ?? DictationError.audioUnavailable)
                }
            }
        }
    }
    public func stop(session: UUID) async throws -> CapturedAudio {
        let cutoff = mach_absolute_time()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CapturedAudio, Error>) in
            queue.async {
                guard let active = self.active, active.id == session else {
                    continuation.resume(throwing: DictationError.noAudio); return
                }
                active.stop(cutoff: cutoff, completion: continuation)
            }
        }
    }
    public func cancel(session: UUID?) async {
        await withCheckedContinuation { continuation in
            queue.async {
                if let active = self.active, session == nil || active.id == session {
                    active.abort(.cancelled)
                }
                continuation.resume()
            }
        }
    }
}

private final class CaptureSession {
    let id: UUID
    let engine = AVAudioEngine()
    let queue: DispatchQueue
    let ingress: Ingress
    let policy: ResourcePolicy
    let converter: AudioConversion
    let rate: Double
    private let scratch: UnsafeMutablePointer<Float>
    private var endpoint = AudioEndpoint()
    private var timer: DispatchSourceTimer?
    private var configurationObserver: NSObjectProtocol?
    private var stopCompletion: CheckedContinuation<CapturedAudio, Error>?
    private var cutoff: UInt64?
    private var cutoffSeconds: Double?
    private var startSeconds: Double = 0
    private var lastProgress = 0.0
    private var firstDelivered = false
    private var closed = false
    private let onFirst: @Sendable () -> Void
    private let onProgress: @Sendable (Double, Float) -> Void
    private let onFailure: @Sendable (DictationError) -> Void
    var onFinished: (() -> Void)?

    init(id: UUID, queue: DispatchQueue, deviceID: AudioDeviceID?, channel: Int, policy: ResourcePolicy,
         onFirst: @escaping @Sendable () -> Void, onProgress: @escaping @Sendable (Double, Float) -> Void,
         onFailure: @escaping @Sendable (DictationError) -> Void) throws {
        self.id = id; self.queue = queue; self.policy = policy
        self.onFirst = onFirst; self.onProgress = onProgress; self.onFailure = onFailure
        ingress = try Ingress(policy: policy)
        let input = engine.inputNode
        if var device = deviceID {
            guard let unit = input.audioUnit,
                  AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
                                       0, &device, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
            else { throw DictationError.audioUnavailable }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
              format.sampleRate.isFinite, (8000...192000).contains(format.sampleRate),
              format.channelCount > 0, format.channelCount <= policy.maxInputChannels,
              channel >= 0, channel < Int(format.channelCount)
        else { throw DictationError.unsupportedFormat }
        rate = format.sampleRate
        converter = try AudioConversion(sourceRate: rate, policy: policy)
        scratch = .allocate(capacity: policy.maxNativeBlockFrames)
        scratch.initialize(repeating: 0, count: policy.maxNativeBlockFrames)
        let ring = ingress
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, time in
            // Only fixed metadata access and bounded C copy on the tap path.
            let samples = buffer.floatChannelData?[channel]
            _ = ow_ring_push(ring.pointer, samples, buffer.frameLength,
                time.hostTime, time.sampleTime, time.isHostTimeValid ? 1 : 0, time.isSampleTimeValid ? 1 : 0)
        }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
                // Never stop/deallocate an engine synchronously in its notification.
                queue.async { [weak self] in self?.abort(.discontinuity) }
            }
    }
    deinit {
        scratch.deinitialize(count: policy.maxNativeBlockFrames); scratch.deallocate()
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
    }
    func start() throws {
        startSeconds = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        engine.prepare()
        try engine.start()
        let clock = DispatchSource.makeTimerSource(queue: queue)
        clock.schedule(deadline: .now(), repeating: .milliseconds(policy.pumpIntervalMilliseconds),
                       leeway: .milliseconds(2))
        clock.setEventHandler { [weak self] in self?.pump() }
        timer = clock; clock.resume()
    }
    func stop(cutoff: UInt64, completion: CheckedContinuation<CapturedAudio, Error>) {
        guard !closed, stopCompletion == nil else { completion.resume(throwing: DictationError.busy); return }
        self.cutoff = cutoff; cutoffSeconds = AVAudioTime.seconds(forHostTime: cutoff)
        stopCompletion = completion
        do { try endpoint.requireUnprocessedCutoff(AVAudioTime.seconds(forHostTime: cutoff)) }
        catch { abort(.endpointUncertain); return }
        pump()
    }
    private func pump() {
        guard !closed else { return }
        do {
            if ow_ring_losses(ingress.pointer) != 0 { throw DictationError.overflow }
            var block = ow_block()
            var level: Float = 0
            // At most the configured ring capacity per timer event.
            for _ in 0..<policy.ringSlots {
                let rc = ow_ring_pop(ingress.pointer, scratch, UInt32(policy.maxNativeBlockFrames), &block)
                if rc == 0 { break }
                guard rc == 1 else { throw DictationError.overflow }
                let accepted = try endpoint.accept(frames: Int(block.frames),
                    sampleTime: block.sample_valid == 1 ? block.sample_time : nil,
                    hostSeconds: block.host_valid == 1 ? AVAudioTime.seconds(forHostTime: block.host_time) : nil,
                    rate: rate, cutoff: cutoffSeconds)
                if accepted > 0 {
                    try converter.append(UnsafeBufferPointer(start: scratch, count: accepted))
                    for i in 0..<accepted { level = max(level, abs(scratch[i])) }
                    if !firstDelivered { firstDelivered = true; onFirst() }
                }
                if let cutoffSeconds, endpoint.covers(cutoffSeconds) { break }
            }
            let now = AVAudioTime.seconds(forHostTime: mach_absolute_time())
            if !firstDelivered && now - startSeconds >= policy.firstBufferTimeoutSeconds { throw DictationError.audioUnavailable }
            if now - startSeconds >= Double(policy.sessionLimitSeconds) { throw DictationError.durationLimit }
            if now - lastProgress >= 0.1 {
                lastProgress = now; onProgress(Double(converter.count) / Double(policy.sampleRate), min(level, 1))
            }
            if let cutoffSeconds {
                if endpoint.covers(cutoffSeconds) { try complete() }
                else if now - cutoffSeconds >= policy.stopDrainTimeoutSeconds { throw DictationError.endpointUncertain }
            }
        } catch { abort((error as? DictationError) ?? .audioUnavailable) }
    }
    private func complete() throws {
        guard let cutoff, let completion = stopCompletion else { throw DictationError.endpointUncertain }
        shutdown()
        let closedAt = mach_absolute_time()
        do {
            let pcm = try converter.finish()
            stopCompletion = nil
            completion.resume(returning: CapturedAudio(pcm: pcm, firstHostTime: ow_ring_first_host(ingress.pointer),
                stopHostTime: cutoff, closedHostTime: closedAt, nativeRate: rate))
            onFinished?()
        } catch {
            stopCompletion = nil; completion.resume(throwing: error); onFinished?()
        }
    }
    func shutdown() {
        guard !closed else { return }
        closed = true
        ow_ring_close(ingress.pointer)
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        timer?.setEventHandler {}; timer?.cancel(); timer = nil
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
    }
    func abort(_ error: DictationError) {
        guard !closed else { return }
        shutdown()
        if let completion = stopCompletion { stopCompletion = nil; completion.resume(throwing: error) }
        else { onFailure(error) }
        onFinished?()
    }
}
