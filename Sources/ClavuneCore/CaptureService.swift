import AVFAudio
import AVFoundation
import AudioToolbox
import CoreAudio
import Carbon
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

public enum CaptureCompletionReason: Equatable, Sendable {
    case requestedStop, sessionLimit
}

public struct CapturedAudio: Sendable {
    public let pcm: SessionPCM
    public let firstHostTime: UInt64
    public let stopHostTime: UInt64
    public let closedHostTime: UInt64
    public let nativeRate: Double
    public let completionReason: CaptureCompletionReason
    public init(pcm: SessionPCM, firstHostTime: UInt64, stopHostTime: UInt64,
                closedHostTime: UInt64, nativeRate: Double,
                completionReason: CaptureCompletionReason = .requestedStop) {
        self.pcm = pcm; self.firstHostTime = firstHostTime; self.stopHostTime = stopHostTime
        self.closedHostTime = closedHostTime; self.nativeRate = nativeRate
        self.completionReason = completionReason
    }
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

public protocol CaptureServicing: CaptureStopping {
    func start(session: UUID, deviceID: AudioDeviceID?, channel: Int, policy: ResourcePolicy,
               authorization: CaptureStartupGate, onFirstSample: @escaping @Sendable () -> Void,
               onProgress: @escaping @Sendable (Double, Float) -> Void,
               onFailure: @escaping @Sendable (DictationError) -> Void,
               onLimitReached: @escaping @Sendable (CaptureStopRequest) -> Void) async throws
    func cancel(session: UUID?) async
}

/// Engine/pump resources only. Admission, privacy and queue delivery live in CaptureService.
/// Every implementation must make shutdown idempotent; all calls run serially on the control queue.
protocol CaptureRunning: AnyObject {
    var id: UUID { get }
    var onFinished: (() -> Void)? { get set }
    func prepare() throws
    func start() throws
    func beginPumping()
    func stop(cutoff: UInt64, completion: CheckedContinuation<CapturedAudio, Error>)
    func shutdown()
    func abort(_ error: DictationError)
}

struct CaptureRunConfiguration {
    let id: UUID
    let queue: DispatchQueue
    let deviceID: AudioDeviceID?
    let channel: Int
    let policy: ResourcePolicy
    let onFirst: @Sendable () -> Void
    let onProgress: @Sendable (Double, Float) -> Void
    let onFailure: @Sendable (DictationError) -> Void
    let onLimitReached: @Sendable (CaptureStopRequest) -> Void
}

/// All AVAudioEngine lifecycle work and conversion is serialized on queue.
/// The callback owns only its ingress reference; borrowed framework buffers never escape it.
public final class CaptureService: CaptureServicing, @unchecked Sendable {
    private let queue: DispatchQueue
    private let enqueue: @Sendable (@escaping @Sendable () -> Void) -> Void
    private let privacyAllowsCapture: @Sendable () -> Bool
    private let makeRun: @Sendable (CaptureRunConfiguration) throws -> any CaptureRunning
    private var active: (any CaptureRunning)?
    public convenience init() {
        self.init(queue: DispatchQueue(label: "org.clavune.capture", qos: .userInitiated),
                  privacyAllowsCapture: {
                      AVCaptureDevice.authorizationStatus(for: .audio) == .authorized && !IsSecureEventInputEnabled()
                  }, makeRun: { configuration in
                      try CaptureSession(id: configuration.id, queue: configuration.queue,
                          deviceID: configuration.deviceID, channel: configuration.channel,
                          policy: configuration.policy, onFirst: configuration.onFirst,
                          onProgress: configuration.onProgress, onFailure: configuration.onFailure,
                          onLimitReached: configuration.onLimitReached)
                  })
    }
    /// Internal composition seam: tests replace resources/delivery, never the service algorithm.
    init(queue: DispatchQueue,
         enqueue: (@Sendable (@escaping @Sendable () -> Void) -> Void)? = nil,
         privacyAllowsCapture: @escaping @Sendable () -> Bool,
         makeRun: @escaping @Sendable (CaptureRunConfiguration) throws -> any CaptureRunning) {
        self.queue = queue
        self.enqueue = enqueue ?? { work in queue.async(execute: work) }
        self.privacyAllowsCapture = privacyAllowsCapture; self.makeRun = makeRun
    }
    public func start(session: UUID, deviceID: AudioDeviceID?, channel: Int, policy: ResourcePolicy,
                      authorization: CaptureStartupGate,
                      onFirstSample: @escaping @Sendable () -> Void,
                      onProgress: @escaping @Sendable (Double, Float) -> Void,
                      onFailure: @escaping @Sendable (DictationError) -> Void,
                      onLimitReached: @escaping @Sendable (CaptureStopRequest) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            enqueue {
                guard self.active == nil else { continuation.resume(throwing: DictationError.busy); return }
                var acquired: (any CaptureRunning)?
                do {
                    try authorization.check(privacyAllowsCapture: self.privacyAllowsCapture)
                    let run = try self.makeRun(CaptureRunConfiguration(id: session, queue: self.queue,
                        deviceID: deviceID, channel: channel, policy: policy, onFirst: onFirstSample,
                        onProgress: onProgress, onFailure: onFailure, onLimitReached: onLimitReached))
                    acquired = run; self.active = run
                    run.onFinished = { [weak owner = self, weak run] in
                        if let run, owner?.active === run { owner?.active = nil }
                    }
                    try authorization.check(privacyAllowsCapture: self.privacyAllowsCapture)
                    try run.prepare()
                    guard self.active === run else { throw DictationError.audioUnavailable }
                    try authorization.start(privacyAllowsCapture: self.privacyAllowsCapture,
                                            open: { try run.start() }, close: { run.shutdown() })
                    guard self.active === run else { throw DictationError.audioUnavailable }
                    run.beginPumping()
                    continuation.resume()
                } catch {
                    acquired?.shutdown()
                    if let acquired, self.active === acquired { self.active = nil }
                    continuation.resume(throwing: (error as? DictationError) ?? DictationError.audioUnavailable)
                }
            }
        }
    }
    public func stop(_ request: CaptureStopRequest) async throws -> CapturedAudio {
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CapturedAudio, Error>) in
            enqueue {
                guard let active = self.active, active.id == request.session else {
                    continuation.resume(throwing: DictationError.noAudio); return
                }
                active.stop(cutoff: request.cutoffHostTime, completion: continuation)
            }
        }
    }
    public func cancel(session: UUID?) async {
        await withCheckedContinuation { continuation in
            enqueue {
                if let active = self.active, session == nil || active.id == session {
                    active.abort(.cancelled)
                }
                continuation.resume()
            }
        }
    }
}

private final class CaptureSession: CaptureRunning {
    let id: UUID
    let engine = AVAudioEngine()
    let queue: DispatchQueue
    let ingress: Ingress
    let policy: ResourcePolicy
    private var buffer: LiveCaptureBuffer?
    let rate: Double
    private let scratch: UnsafeMutablePointer<Float>
    private var limitHandoff = CaptureLimitHandoff()
    private var timer: DispatchSourceTimer?
    private var configurationObserver: NSObjectProtocol?
    private var stopCompletion: CheckedContinuation<CapturedAudio, Error>?
    private var requestedCutoff: UInt64?
    private var startSeconds: Double = 0
    private var lastProgress = 0.0
    private var meterPeak = CapturePeakAccumulator()
    private var firstDelivered = false
    private var closed = false
    private let onFirst: @Sendable () -> Void
    private let onProgress: @Sendable (Double, Float) -> Void
    private let onFailure: @Sendable (DictationError) -> Void
    private let onLimitReached: @Sendable (CaptureStopRequest) -> Void
    var onFinished: (() -> Void)?

    init(id: UUID, queue: DispatchQueue, deviceID: AudioDeviceID?, channel: Int, policy: ResourcePolicy,
         onFirst: @escaping @Sendable () -> Void, onProgress: @escaping @Sendable (Double, Float) -> Void,
         onFailure: @escaping @Sendable (DictationError) -> Void,
         onLimitReached: @escaping @Sendable (CaptureStopRequest) -> Void) throws {
        self.id = id; self.queue = queue; self.policy = policy
        self.onFirst = onFirst; self.onProgress = onProgress; self.onFailure = onFailure
        self.onLimitReached = onLimitReached
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
        scratch = .allocate(capacity: policy.maxNativeBlockFrames)
        scratch.initialize(repeating: 0, count: policy.maxNativeBlockFrames)
        let ring = ingress
        let nativeRate = rate
        let hostTicksPerSecond = Double(AVAudioTime.hostTime(forSeconds: 1))
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, time in
            // Only fixed metadata access and bounded C copy on the tap path.
            let samples = buffer.floatChannelData?[channel]
            _ = ow_ring_push_buffer(ring.pointer, samples, buffer.frameLength,
                time.hostTime, time.sampleTime, time.isHostTimeValid ? 1 : 0, time.isSampleTimeValid ? 1 : 0,
                nativeRate, hostTicksPerSecond)
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
    func prepare() throws {
        startSeconds = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        buffer = try LiveCaptureBuffer(rate: rate, policy: policy, startSeconds: startSeconds)
        engine.prepare()
    }
    func start() throws { try engine.start() }
    func beginPumping() {
        let clock = DispatchSource.makeTimerSource(queue: queue)
        clock.schedule(deadline: .now(), repeating: .milliseconds(policy.pumpIntervalMilliseconds),
                       leeway: .milliseconds(2))
        clock.setEventHandler { [weak self] in self?.pump() }
        timer = clock; clock.resume()
    }
    func stop(cutoff: UInt64, completion: CheckedContinuation<CapturedAudio, Error>) {
        if limitHandoff.isPending {
            do { completion.resume(returning: try limitHandoff.take(cutoffHostTime: cutoff)) }
            catch { completion.resume(throwing: error) }
            onFinished?()
            return
        }
        guard !closed, stopCompletion == nil else { completion.resume(throwing: DictationError.busy); return }
        requestedCutoff = cutoff; stopCompletion = completion
        do { try buffer?.requestStop(at: AVAudioTime.seconds(forHostTime: cutoff)) }
        catch { abort(.endpointUncertain); return }
        pump()
    }
    private func pump() {
        guard !closed, let buffer else { return }
        do {
            if ow_ring_losses(ingress.pointer) != 0 { throw DictationError.overflow }
            var block = ow_block()
            var level: Float = 0
            // At most the configured ring capacity per timer event.
            for _ in 0..<policy.ringSlots {
                let rc = ow_ring_pop(ingress.pointer, scratch, UInt32(policy.maxNativeBlockFrames), &block)
                if rc == 0 { break }
                guard rc == 1 else { throw DictationError.overflow }
                let peak = try buffer.append(UnsafeBufferPointer(start: scratch, count: Int(block.frames)),
                    sampleTime: block.sample_valid == 1 ? block.sample_time : nil,
                    hostSeconds: block.host_valid == 1 ? AVAudioTime.seconds(forHostTime: block.host_time) : nil)
                level = max(level, peak)
                if buffer.acceptedNativeFrames > 0, !firstDelivered { firstDelivered = true; onFirst() }
                if buffer.endIsCovered { break }
            }
            meterPeak.observe(level)
            let now = AVAudioTime.seconds(forHostTime: mach_absolute_time())
            if !firstDelivered && now - startSeconds >= policy.firstBufferTimeoutSeconds { throw DictationError.audioUnavailable }
            if try buffer.shouldFinish(now: now) { complete(buffer); return }
            if now - lastProgress >= 0.1 {
                lastProgress = now
                onProgress(Double(buffer.count) / Double(policy.sampleRate), meterPeak.take())
            }
        } catch { abort((error as? DictationError) ?? .audioUnavailable) }
    }
    private func complete(_ buffer: LiveCaptureBuffer) {
        // Closure precedes conversion flush, notification and all inference admission.
        shutdown()
        let closedAt = mach_absolute_time()
        let completion = stopCompletion; stopCompletion = nil
        do {
            // A loss observed during this pump is not a successful limit completion.
            guard ow_ring_losses(ingress.pointer) == 0 else { throw DictationError.overflow }
            let pcm = try buffer.finish()
            let reason = buffer.completionReason
            let cutoff: UInt64
            if reason == .requestedStop {
                guard let requestedCutoff else { throw DictationError.endpointUncertain }
                cutoff = requestedCutoff
            } else { cutoff = AVAudioTime.hostTime(forSeconds: buffer.endSeconds) }
            let audio = CapturedAudio(pcm: pcm, firstHostTime: ow_ring_first_host(ingress.pointer),
                stopHostTime: cutoff, closedHostTime: closedAt, nativeRate: rate, completionReason: reason)
            self.buffer = nil
            if let completion {
                completion.resume(returning: audio); onFinished?()
            } else {
                try limitHandoff.publish(audio)
                // Keep the bounded result until stop/cancel consumes it; microphone is closed.
                onLimitReached(CaptureStopRequest(session: id, cutoffHostTime: cutoff))
            }
        } catch {
            self.buffer = nil
            if let completion { completion.resume(throwing: error) }
            else { onFailure((error as? DictationError) ?? .audioUnavailable) }
            onFinished?()
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
        // Only cancellation may consume a closed automatic result. Late device
        // notifications cannot invalidate an already-finalized prefix.
        if closed {
            if error == .cancelled, limitHandoff.isPending {
                limitHandoff.cancel(); onFinished?()
            }
            return
        }
        shutdown(); buffer = nil; limitHandoff.cancel()
        if let completion = stopCompletion { stopCompletion = nil; completion.resume(throwing: error) }
        else { onFailure(error) }
        onFinished?()
    }
}
