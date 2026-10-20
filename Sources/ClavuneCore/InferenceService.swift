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
}

/// This queue exclusively owns model weights. Blocking C++ does not run on an actor or UI executor.
/// Caller serializes sessions; each accepted request owns its independent cancellation token.
public final class InferenceService: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.clavune.inference", qos: .userInitiated)
    private var engine: OpaquePointer?
    private var modelHash: String?
    public init() {}
    deinit { if let engine { ow_engine_destroy(engine) } }
    public func load(url: URL, candidate: ModelCandidate) async throws -> (warm: Bool, seconds: Double) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(warm: Bool, seconds: Double), Error>) in
            queue.async {
                if self.engine != nil, self.modelHash == candidate.sha256 {
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
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
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
                continuation.resume(returning: result)
            }
        }
    }
    public func unload() async {
        await withCheckedContinuation { continuation in
            queue.async {
                if let engine = self.engine { ow_engine_destroy(engine) }
                self.engine = nil; self.modelHash = nil
                continuation.resume()
            }
        }
    }
}
