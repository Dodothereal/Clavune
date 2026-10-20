import XCTest
import NativeBridge
@testable import ClavuneCore

final class CoreTests: XCTestCase {
    func testCancellationAndStaleResultsCannotContaminateNextSession() throws {
        var state = SessionMachine()
        let old = try state.begin()
        state.recording(old); XCTAssertTrue(state.stopping(old)); state.transcribing(old)
        state.cancel()
        let current = try state.begin()
        state.result("late old content", session: old)
        state.recording(old)
        XCTAssertEqual(state.phase, .preparing)
        XCTAssertTrue(state.rawTranscript.isEmpty)
        state.recording(current); XCTAssertTrue(state.stopping(current)); state.transcribing(current)
        state.result("Nicht fünfzehn, sondern fünfzig. SwiftUI.", session: current)
        XCTAssertEqual(state.rawTranscript, "Nicht fünfzehn, sondern fünfzig. SwiftUI.")
        state.result("duplicate", session: current)
        XCTAssertEqual(state.rawTranscript, "Nicht fünfzehn, sondern fünfzig. SwiftUI.")
    }
    func testDuplicateStopAndBusyStartAreRejected() throws {
        var state = SessionMachine()
        let id = try state.begin()
        XCTAssertThrowsError(try state.begin())
        state.recording(id); XCTAssertTrue(state.stopping(id)); XCTAssertFalse(state.stopping(id))
    }
    func testRingWrapAndLossAreExplicit() throws {
        let r = try XCTUnwrap(ow_ring_create(3, 4))
        defer { ow_ring_destroy(r) }
        var out = [Float](repeating: 0, count: 4); var m = ow_block()
        for generation in 0..<100 {
            for slot in 0..<3 {
                let v = [Float(generation * 3 + slot)]
                XCTAssertEqual(v.withUnsafeBufferPointer { ow_ring_push(r, $0.baseAddress, 1, UInt64(generation * 3 + slot + 1), 0, 1, 0) }, 1)
            }
            for slot in 0..<3 {
                XCTAssertEqual(ow_ring_pop(r, &out, 4, &m), 1)
                XCTAssertEqual(out[0], Float(generation * 3 + slot))
                XCTAssertEqual(m.sequence, UInt64(generation * 3 + slot))
            }
        }
        XCTAssertEqual(ow_ring_losses(r), 0)
        let sample: [Float] = [1, 2, 3, 4]
        for _ in 0..<3 { _ = sample.withUnsafeBufferPointer { ow_ring_push(r, $0.baseAddress, 4, 1, 0, 1, 0) } }
        XCTAssertEqual(sample.withUnsafeBufferPointer { ow_ring_push(r, $0.baseAddress, 4, 1, 0, 1, 0) }, 0)
        XCTAssertEqual(ow_ring_losses(r), 1)
        ow_ring_close(r)
        XCTAssertEqual(sample.withUnsafeBufferPointer { ow_ring_push(r, $0.baseAddress, 4, 1, 0, 1, 0) }, 0)
        XCTAssertEqual(ow_ring_losses(r), 1)
    }
    func testOversizedIngressNeverTruncatesSilently() throws {
        let r = try XCTUnwrap(ow_ring_create(2, 2))
        defer { ow_ring_destroy(r) }
        let v: [Float] = [1, 2, 3]
        XCTAssertEqual(v.withUnsafeBufferPointer { ow_ring_push(r, $0.baseAddress, 3, 1, 0, 1, 0) }, 0)
        XCTAssertEqual(ow_ring_losses(r), 1)
        var out = [Float](repeating: 0, count: 2); var m = ow_block()
        XCTAssertEqual(ow_ring_pop(r, &out, 2, &m), 0)
    }
    func testCutoffIncludesTailAndRejectsDiscontinuity() throws {
        var timeline = AudioEndpoint()
        XCTAssertEqual(try timeline.accept(frames: 240, sampleTime: 0, hostSeconds: 10, rate: 24000, cutoff: nil), 240)
        XCTAssertFalse(timeline.covers(10.015))
        XCTAssertEqual(try timeline.accept(frames: 240, sampleTime: 240, hostSeconds: 10.01, rate: 24000, cutoff: 10.015), 120)
        XCTAssertTrue(timeline.covers(10.015))
        XCTAssertThrowsError(try timeline.accept(frames: 240, sampleTime: 1000, hostSeconds: 10.02, rate: 24000, cutoff: nil))
    }
    func testUnknownTimestampsFailClosed() throws {
        var timeline = AudioEndpoint()
        XCTAssertThrowsError(try timeline.accept(frames: 10, sampleTime: 0, hostSeconds: nil, rate: 24000, cutoff: nil))
        XCTAssertFalse(timeline.covers(1))
    }
    func testQueuedStopRejectsAlreadyConvertedPostCutoffAudio() throws {
        var endpoint = AudioEndpoint()
        // Simulate a pump that consumed a second block before its queued stop action.
        _ = try endpoint.accept(frames: 240, sampleTime: 0, hostSeconds: 10, rate: 24000, cutoff: nil)
        _ = try endpoint.accept(frames: 240, sampleTime: 240, hostSeconds: 10.01, rate: 24000, cutoff: nil)
        XCTAssertThrowsError(try endpoint.requireUnprocessedCutoff(10.015)) {
            XCTAssertEqual($0 as? DictationError, .endpointUncertain)
        }
        // No trimming of an already contaminated resampler state is claimed.
        XCTAssertNoThrow(try endpoint.requireUnprocessedCutoff(10.02))
    }
    private func converted(rate: Double, chunk: Int, samples: [Float]) throws -> [Float] {
        let c = try AudioConversion(sourceRate: rate, policy: ResourcePolicy.bundled())
        try samples.withUnsafeBufferPointer { input in
            var cursor = 0
            while cursor < input.count {
                let n = min(chunk, input.count - cursor)
                try c.append(UnsafeBufferPointer(start: input.baseAddress! + cursor, count: n))
                cursor += n
            }
        }
        return try c.finish().samples
    }
    func testNativeRateConversionIsContinuousAndChunkInvariant() throws {
        for rate in [16000.0, 24000, 44100, 48000] {
            let source = (0..<Int(rate)).map { Float(sin(2 * Double.pi * 440 * Double($0) / rate) * 0.25) }
            let a = try converted(rate: rate, chunk: 4096, samples: source)
            let b = try converted(rate: rate, chunk: 317, samples: source)
            XCTAssertEqual(a.count, 16000, accuracy: 2, "rate \(rate)")
            XCTAssertEqual(a.count, b.count, "duration changed with chunking at \(rate)")
            let error = zip(a, b).map { abs($0 - $1) }.max() ?? 1
            XCTAssertLessThan(error, 0.0001, "input replay or converter reset at \(rate)")
            let rms = sqrt(a.reduce(0) { $0 + Double($1 * $1) } / Double(a.count))
            XCTAssertEqual(rms, 0.1768, accuracy: 0.01)
        }
    }
    func testConverterDrainsLastSamplesAndRejectsNonfiniteInput() throws {
        var source = [Float](repeating: 0, count: 24000)
        for i in 23900..<24000 { source[i] = 0.5 }
        let out = try converted(rate: 24000, chunk: 317, samples: source)
        XCTAssertGreaterThan(out.suffix(200).map { abs($0) }.max() ?? 0, 0.3)
        let c = try AudioConversion(sourceRate: 24000, policy: ResourcePolicy.bundled())
        XCTAssertThrowsError(try [Float.nan].withUnsafeBufferPointer { try c.append($0) })
    }
    func testManifestContainsRealHashesButNoPromotedDefault() throws {
        let candidates = try ModelStore.candidates()
        XCTAssertEqual(candidates.count, 4)
        XCTAssertTrue(candidates.allSatisfy { $0.sha256.count == 64 && $0.sizeBytes > 0 && $0.qualityGate == "unmeasured" })
        let policy = try ResourcePolicy.bundled()
        XCTAssertFalse(policy.previewEnabled)
        XCTAssertEqual(policy.activeInferenceJobs, 1)
        XCTAssertEqual(policy.maxSamples, 1_920_000)
    }
    func testModelImportRejectsUnexpectedBytesWithoutInstalling() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let root = project
            .appendingPathComponent(".build/model-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("unexpected.bin")
        try Data([1, 2, 3]).write(to: source)
        let destination = root.appendingPathComponent("installed")
        XCTAssertThrowsError(try ModelStore.importModel(source, into: destination, candidates: ModelStore.candidates()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: source), Data([1, 2, 3]))
    }
}
