import XCTest
@testable import ClavuneCore

final class CapturePeakAccumulatorTests: XCTestCase {
    func testAudibleBufferBetweenEmptyPumpTicksSurvivesUntilCoalescedEmission() {
        var meter = CapturePeakAccumulator()
        // Ten synthetic 10-ms pump ticks share a single 100-ms UI update.
        // The audible buffer arrives early; the final tick contains no audio.
        let pumpPeaks: [Float] = [0, 0, 0.8, 0, 0, 0, 0, 0, 0, 0]
        for peak in pumpPeaks { meter.observe(peak) }
        XCTAssertEqual(meter.take(), 0.8)
    }

    func testEmissionResetsPeakForNextWindowWithoutLosingItsMaximum() {
        var meter = CapturePeakAccumulator()
        meter.observe(0.9)
        XCTAssertEqual(meter.take(), 0.9)
        for _ in 0..<10 { meter.observe(0) }
        XCTAssertEqual(meter.take(), 0)
        let nextPeaks: [Float] = [0.2, 0.5, 0.1, 0]
        for peak in nextPeaks { meter.observe(peak) }
        XCTAssertEqual(meter.take(), 0.5)
        XCTAssertEqual(meter.take(), 0)
    }
}
