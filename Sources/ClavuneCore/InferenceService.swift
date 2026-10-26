import Foundation
import NativeBridge

public final class DecodeCancellation: @unchecked Sendable {
    let pointer: OpaquePointer
    public init() throws {
        guard let p = ow_cancel_create() else { throw DictationError.inferenceFailed }
        pointer = p
    }
    public func cancel() { ow_cancel_set(pointer) }
    deinit { ow_cancel_destroy(pointer) }
}

public struct TranscriptionResult: Sendable {
    public let text: String
    public let languageID: Int
    public let decodeSeconds: Double
    public init(text: String, languageID: Int, decodeSeconds: Double) {
        self.text = text; self.languageID = languageID; self.decodeSeconds = decodeSeconds
    }
}

public protocol InferenceServicing: Sendable {
    func load(url: URL, candidate: ModelCandidate) async throws -> (warm: Bool, seconds: Double)
    func transcribe(_ pcm: SessionPCM, language: LanguageMode,
                    cancellation: DecodeCancellation, policy: ResourcePolicy) async throws -> TranscriptionResult
    func unload() async
}

/// This queue exclusively owns model weights. Blocking C++ does not run on an actor or UI executor.
/// Caller serializes sessions; each accepted request owns its independent cancellation token.
public final class InferenceService: InferenceServicing, @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.clavune.inference", qos: .userInitiated)
    private var engine: OpaquePointer?
    private var modelHash: String?
    private let measurement: EfficiencyRecorder?
    public init(measurement: EfficiencyRecorder? = nil) { self.measurement = measurement }
    deinit { if let engine { ow_engine_destroy(engine) } }
    public func load(url: URL, candidate: ModelCandidate) async throws -> (warm: Bool, seconds: Double) {
        let ticket = measurement?.ticket()
        ticket?.mark(.load_submission_requested)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(warm: Bool, seconds: Double), Error>) in
            queue.async {
                ticket?.mark(.load_queue_started)
                defer { ticket?.mark(.load_work_drained) }
                if self.engine != nil, self.modelHash == candidate.sha256 {
                    ticket?.mark(.model_context_reused)
                    continuation.resume(returning: (true, 0)); return
                }
                if let previous = self.engine { ow_engine_destroy(previous) }
                self.engine = nil; self.modelHash = nil
                let start = DispatchTime.now().uptimeNanoseconds
                guard let loaded = url.path.withCString({ ow_engine_create($0, 1) }) else {
                    continuation.resume(throwing: DictationError.modelInvalid); return
                }
                self.engine = loaded; self.modelHash = candidate.sha256
                continuation.resume(returning: (false, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9))
            }
        }
    }
    public func transcribe(_ pcm: SessionPCM, language: LanguageMode,
                           cancellation: DecodeCancellation, policy: ResourcePolicy) async throws -> TranscriptionResult {
        guard !pcm.samples.isEmpty, pcm.samples.count <= policy.maxSamples else {
            throw DictationError.noAudio
        }
        let ticket = measurement?.ticket()
        ticket?.mark(.decode_submission_requested)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                ticket?.mark(.decode_queue_started)
                // Registered first: Swift executes output destruction's later defer first.
                defer { ticket?.mark(.decode_work_drained) }
                guard let engine = self.engine else {
                    continuation.resume(throwing: DictationError.modelMissing); return
                }
                let start = DispatchTime.now().uptimeNanoseconds
                let output = pcm.samples.withUnsafeBufferPointer { samples in
                    language.rawValue.withCString {
                        ow_engine_decode(engine, cancellation.pointer, samples.baseAddress, samples.count,
                                         Int32(pcm.sampleRate), $0, Int32(policy.inferenceThreads))
                    }
                }
                defer { if let output { ow_result_destroy(output) } }
                let status = ow_result_status(output)
                guard status == 0, let output else {
                    continuation.resume(throwing: status == 1 ? DictationError.cancelled : DictationError.inferenceFailed)
                    return
                }
                let result = TranscriptionResult(text: String(cString: ow_result_text(output)),
                    languageID: Int(ow_result_language(output)),
                    decodeSeconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
                ticket?.mark(.decode_result_created)
                continuation.resume(returning: result)
            }
        }
    }
    /// Development harness queue barrier only. It does not unload the reusable model context.
    /// Await after a returned/throwing operation before finishing the matching ticket.
    /// Prior queue work and result destruction precede this barrier. This does not prove
    /// release of every retained PCM/framework owner, process exit, or successful transcription.
    public func drainForMeasurement() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }
    public func unload() async {
        let ticket = measurement?.ticket()
        ticket?.mark(.unload_submission_requested)
        await withCheckedContinuation { continuation in
            queue.async {
                ticket?.mark(.unload_queue_started)
                defer { ticket?.mark(.unload_work_drained) }
                if let engine = self.engine { ow_engine_destroy(engine) }
                self.engine = nil; self.modelHash = nil
                continuation.resume()
            }
        }
    }
}
