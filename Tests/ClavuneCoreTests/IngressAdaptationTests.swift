import XCTest
import NativeBridge

final class IngressAdaptationTests: XCTestCase {
    func testLargeCallbackPreservesFIFOAndNativeTimestamps() throws {
        let maxFrames: UInt32 = 4096
        let samples = (0..<10_000).map { Float($0) }
        let ticksPerSecond = 24_000_000.0
        let firstHost: UInt64 = 1_000_000
        let firstSample: Int64 = 100_000
        for rate in [24_000.0, 44_100.0, 48_000.0] {
            let ring = try XCTUnwrap(ow_ring_create(4, maxFrames))
            defer { ow_ring_destroy(ring) }
            XCTAssertEqual(samples.withUnsafeBufferPointer {
                ow_ring_push_buffer(ring, $0.baseAddress, UInt32($0.count),
                    firstHost, firstSample, 1, 1, rate, ticksPerSecond)
            }, 1)
            var output = [Float](repeating: 0, count: Int(maxFrames))
            var metadata = ow_block()
            var received: [Float] = []
            for (sequence, offset) in [0, 4096, 8192].enumerated() {
                XCTAssertEqual(output.withUnsafeMutableBufferPointer {
                    ow_ring_pop(ring, $0.baseAddress, maxFrames, &metadata)
                }, 1)
                let expectedFrames = min(Int(maxFrames), samples.count - offset)
                XCTAssertEqual(metadata.frames, UInt32(expectedFrames))
                XCTAssertEqual(metadata.sequence, UInt64(sequence))
                XCTAssertEqual(metadata.sample_time, firstSample + Int64(offset))
                let expectedDelta = UInt64((Double(offset) * ticksPerSecond / rate).rounded())
                XCTAssertEqual(metadata.host_time, firstHost + expectedDelta)
                XCTAssertEqual(metadata.host_valid, 1)
                XCTAssertEqual(metadata.sample_valid, 1)
                received.append(contentsOf: output.prefix(expectedFrames))
            }
            XCTAssertEqual(received, samples)
            XCTAssertEqual(ow_ring_losses(ring), 0)
            XCTAssertEqual(ow_ring_first_host(ring), firstHost)
            XCTAssertEqual(output.withUnsafeMutableBufferPointer {
                ow_ring_pop(ring, $0.baseAddress, maxFrames, &metadata)
            }, 0)
        }
    }

    func testInsufficientFreeSlotsRejectEntireCallbackWithoutPartialPublication() throws {
        let ring = try XCTUnwrap(ow_ring_create(4, 4))
        defer { ow_ring_destroy(ring) }
        let original: [Float] = [7, 8, 9, 10]
        XCTAssertEqual(original.withUnsafeBufferPointer {
            ow_ring_push(ring, $0.baseAddress, 4, 77, 0, 1, 1)
        }, 1)
        // This fits total capacity but needs four slots while only three are free.
        let large = (0..<13).map { Float($0) }
        XCTAssertEqual(large.withUnsafeBufferPointer {
            ow_ring_push_buffer(ring, $0.baseAddress, UInt32($0.count), 1_000, 4, 1, 1, 24_000, 24_000_000)
        }, 0)
        XCTAssertEqual(ow_ring_losses(ring), 1)
        var output = [Float](repeating: 0, count: 4)
        var metadata = ow_block()
        XCTAssertEqual(output.withUnsafeMutableBufferPointer {
            ow_ring_pop(ring, $0.baseAddress, 4, &metadata)
        }, 1)
        XCTAssertEqual(output, original)
        XCTAssertEqual(metadata.sequence, 0)
        XCTAssertEqual(output.withUnsafeMutableBufferPointer {
            ow_ring_pop(ring, $0.baseAddress, 4, &metadata)
        }, 0)
        // After freeing the old slot, the same callback fits, including wraparound.
        XCTAssertEqual(large.withUnsafeBufferPointer {
            ow_ring_push_buffer(ring, $0.baseAddress, UInt32($0.count), 1_000, 4, 1, 1, 24_000, 24_000_000)
        }, 1)
        var received: [Float] = []
        for sequence in 1...4 {
            XCTAssertEqual(output.withUnsafeMutableBufferPointer {
                ow_ring_pop(ring, $0.baseAddress, 4, &metadata)
            }, 1)
            XCTAssertEqual(metadata.sequence, UInt64(sequence))
            received.append(contentsOf: output.prefix(Int(metadata.frames)))
        }
        XCTAssertEqual(received, large)
        XCTAssertEqual(ow_ring_losses(ring), 1)
        XCTAssertEqual(ow_ring_first_host(ring), 77)
    }

    func testCallbackBeyondTotalCapacityPublishesNothing() throws {
        let ring = try XCTUnwrap(ow_ring_create(3, 4))
        defer { ow_ring_destroy(ring) }
        let oversized = [Float](repeating: 1, count: 13)
        XCTAssertEqual(oversized.withUnsafeBufferPointer {
            ow_ring_push_buffer(ring, $0.baseAddress, UInt32($0.count), 100, 0, 1, 1, 24_000, 24_000_000)
        }, 0)
        XCTAssertEqual(ow_ring_losses(ring), 1)
        XCTAssertEqual(ow_ring_first_host(ring), 0)
        var output = [Float](repeating: 0, count: 4)
        var metadata = ow_block()
        XCTAssertEqual(output.withUnsafeMutableBufferPointer {
            ow_ring_pop(ring, $0.baseAddress, 4, &metadata)
        }, 0)
        ow_ring_close(ring)
        XCTAssertEqual(oversized.withUnsafeBufferPointer {
            ow_ring_push_buffer(ring, $0.baseAddress, UInt32($0.count), 100, 0, 1, 1, 24_000, 24_000_000)
        }, 0)
        XCTAssertEqual(ow_ring_losses(ring), 1)
    }

    func testInvalidTimestampArithmeticRejectsBeforePublishing() throws {
        let ring = try XCTUnwrap(ow_ring_create(3, 4))
        defer { ow_ring_destroy(ring) }
        let samples = [Float](repeating: 1, count: 8)
        XCTAssertEqual(samples.withUnsafeBufferPointer {
            ow_ring_push_buffer(ring, $0.baseAddress, 8, UInt64.max - 1, 0, 1, 1, 24_000, 24_000_000)
        }, 0)
        XCTAssertEqual(samples.withUnsafeBufferPointer {
            ow_ring_push_buffer(ring, $0.baseAddress, 8, 100, Int64.max - 1, 1, 1, 24_000, 24_000_000)
        }, 0)
        XCTAssertEqual(samples.withUnsafeBufferPointer {
            ow_ring_push_buffer(ring, $0.baseAddress, 8, 100, 0, 1, 1, 0, 24_000_000)
        }, 0)
        XCTAssertEqual(ow_ring_losses(ring), 3)
        var output = [Float](repeating: 0, count: 4)
        var metadata = ow_block()
        XCTAssertEqual(output.withUnsafeMutableBufferPointer {
            ow_ring_pop(ring, $0.baseAddress, 4, &metadata)
        }, 0)
    }
}
