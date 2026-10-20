import AVFAudio
import XCTest
@testable import ClavuneCore

/// Primitive endpoint/conversion composition only; service/coordinator wiring is tested separately.
final class CaptureStopTests: XCTestCase {
    func testDelayedTaskPreservesRequestCutoffAndExcludesPostRequestSignalFromPCM() async throws {
        let session = UUID()
        let request = CaptureStopRequest(session: session, cutoffHostTime: AVAudioTime.hostTime(forSeconds: 10.025))
        let delivery = ControlledDelivery()
        let transport = SyntheticStopTransport(delivery: delivery, alreadyConvertedPostCutoff: false)
        var metrics = SessionMetrics(session: session, requestedStart: 0)
        metrics.requestedStop = request.cutoffHostTime
        let operation = Task { try await transport.stop(request) }
        await delivery.waitUntilSuspended()
        // Synthetic delivery occurs 50 ms after the stop handler; the request is immutable.
        await delivery.release()
        let audio = try await operation.value
        XCTAssertEqual(audio.stopHostTime, request.cutoffHostTime)
        XCTAssertEqual(metrics.requestedStop, audio.stopHostTime)
        XCTAssertGreaterThan(audio.closedHostTime, audio.stopHostTime)
        XCTAssertEqual(audio.pcm.samples.count, 400, accuracy: 1)
        XCTAssertTrue(audio.pcm.samples.allSatisfy { $0 == 0 })
    }
    func testDelayedStopFailsBeforeReturningPCMIfWorkerAlreadyPassedRequest() async throws {
        let request = CaptureStopRequest(session: UUID(), cutoffHostTime: AVAudioTime.hostTime(forSeconds: 10.025))
        let delivery = ControlledDelivery()
        let transport = SyntheticStopTransport(delivery: delivery, alreadyConvertedPostCutoff: true)
        let operation = Task { try await transport.stop(request) }
        await delivery.waitUntilSuspended(); await delivery.release()
        do {
            _ = try await operation.value
            XCTFail("No PCM may be returned from a resampler that consumed post-cutoff input.")
        } catch { XCTAssertEqual(error as? DictationError, .endpointUncertain) }
    }
}

private actor SyntheticStopTransport: CaptureStopping {
    let delivery: ControlledDelivery
    let alreadyConvertedPostCutoff: Bool
    init(delivery: ControlledDelivery, alreadyConvertedPostCutoff: Bool) {
        self.delivery = delivery; self.alreadyConvertedPostCutoff = alreadyConvertedPostCutoff
    }
    func stop(_ request: CaptureStopRequest) async throws -> CapturedAudio {
        await delivery.suspend()
        let policy = try ResourcePolicy.bundled()
        let converter = try AudioConversion(sourceRate: 24000, policy: policy)
        var endpoint = AudioEndpoint()
        let silence = [Float](repeating: 0, count: 240)
        for index in 0..<(alreadyConvertedPostCutoff ? 4 : 2) {
            let count = try endpoint.accept(frames: 240, sampleTime: Int64(index * 240),
                                           hostSeconds: 10 + Double(index) * 0.01, rate: 24000, cutoff: nil)
            try silence.withUnsafeBufferPointer { try converter.append(UnsafeBufferPointer(rebasing: $0[..<count])) }
        }
        try endpoint.requireUnprocessedCutoff(request.cutoffSeconds)
        // The pending native block contains a strong signal strictly after the original cutoff.
        let pending = [Float](repeating: 0, count: 120) + [Float](repeating: 0.9, count: 120)
        let accepted = try endpoint.accept(frames: pending.count, sampleTime: 480,
                                           hostSeconds: 10.02, rate: 24000, cutoff: request.cutoffSeconds)
        try pending.withUnsafeBufferPointer { try converter.append(UnsafeBufferPointer(rebasing: $0[..<accepted])) }
        XCTAssertTrue(endpoint.covers(request.cutoffSeconds))
        return CapturedAudio(pcm: try converter.finish(), firstHostTime: AVAudioTime.hostTime(forSeconds: 10),
                             stopHostTime: request.cutoffHostTime,
                             closedHostTime: AVAudioTime.hostTime(forSeconds: 10.075), nativeRate: 24000)
    }
}
