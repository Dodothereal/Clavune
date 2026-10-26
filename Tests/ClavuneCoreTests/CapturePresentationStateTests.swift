import Combine
import XCTest
@testable import ClavuneApp

/// Candidate tests only. Not compiled or executed in the Linux review environment.
final class CapturePresentationStateTests: XCTestCase {
    @MainActor func testOnePublicationContainsBothAuthoritativeValues() {
        let state = CapturePresentationState()
        var delivered: [CapturePresentationSample] = []
        let observation = state.$sample.dropFirst().sink { delivered.append($0) }
        state.accept(seconds: 0.1275, peak: 0.75)
        XCTAssertEqual(delivered, [CapturePresentationSample(seconds: 0.1275, peak: 0.75)])
        XCTAssertEqual(state.sample, delivered[0])
        withExtendedLifetime(observation) {}
    }

    @MainActor func testIdenticalSamplesAndRepeatedResetsDoNotRepublish() {
        let state = CapturePresentationState()
        var count = 0
        let observation = state.objectWillChange.sink { count += 1 }
        state.reset()
        state.accept(seconds: 0, peak: 0)
        XCTAssertEqual(count, 0)
        state.accept(seconds: 1, peak: 0.5)
        state.accept(seconds: 1, peak: 0.5)
        XCTAssertEqual(count, 1)
        state.reset()
        state.reset()
        XCTAssertEqual(count, 2)
        withExtendedLifetime(observation) {}
    }

    @MainActor func testClosureClearsLevelWithoutChangingElapsed() {
        let state = CapturePresentationState()
        state.accept(seconds: 7.25, peak: 0.6)
        var count = 0
        let observation = state.objectWillChange.sink { count += 1 }
        state.clearLevel()
        state.clearLevel()
        XCTAssertEqual(state.sample, CapturePresentationSample(seconds: 7.25, peak: 0))
        XCTAssertEqual(count, 1)
        withExtendedLifetime(observation) {}
    }

    @MainActor func testProgressStorageDoesNotPublishCoordinatorChanges() throws {
        let fixture = try CoordinatorFixture()
        var changes = 0
        let observation = fixture.coordinator.objectWillChange.sink { changes += 1 }
        fixture.coordinator.capturePresentation.accept(seconds: 0.1, peak: 0.8)
        fixture.coordinator.capturePresentation.accept(seconds: 0.2, peak: 0.4)
        XCTAssertEqual(changes, 0)
        withExtendedLifetime(observation) {}
    }
}
