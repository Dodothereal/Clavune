import Combine
import XCTest
@testable import ClavuneApp
@testable import ClavuneCore

/// Tests the actual retained CaptureRunConfiguration callback, not a reimplemented guard.
final class ProgressDispatchCompletionTests: UIFixtureAssertions {
    @MainActor func testCapturedCallbackRemainsAsynchronousAndIsAwaitedToCompletion() async throws {
        let fixture = try CoordinatorFixture()
        await startRecording(fixture)
        let id = try XCTUnwrap(fixture.coordinator.session.id)
        let before = fixture.coordinator.capturePresentation.sample
        XCTAssertTrue(fixture.progressDispatcher.takeSubmissions().isEmpty)
        let expected = CapturePresentationSample(seconds: 0.125, peak: 0.75)
        fixture.resources.progress(session: id, seconds: expected.seconds, peak: expected.peak)
        let submissions = fixture.progressDispatcher.takeSubmissions()
        XCTAssertEqual(submissions.count, 1)
        // No suspension since invocation: the queued MainActor work cannot have run inline.
        XCTAssertEqual(fixture.coordinator.capturePresentation.sample, before)
        let submission = try XCTUnwrap(submissions.first)
        guard await awaitProgressTask(submission) else { return }
        XCTAssertEqual(fixture.coordinator.capturePresentation.sample, expected)
        await cancelAndDrain(fixture)
    }

    @MainActor func testEachCapturedInvocationHasItsOwnCompletionHandle() async throws {
        let fixture = try CoordinatorFixture()
        await startRecording(fixture)
        let id = try XCTUnwrap(fixture.coordinator.session.id)
        XCTAssertTrue(fixture.progressDispatcher.takeSubmissions().isEmpty)
        let expected = [CapturePresentationSample(seconds: 0.125, peak: 0.25),
                        CapturePresentationSample(seconds: 0.225, peak: 0.75)]
        var publications: [CapturePresentationSample] = []
        let observation = fixture.coordinator.capturePresentation.$sample.dropFirst()
            .sink { publications.append($0) }
        defer { observation.cancel() }
        for sample in expected {
            fixture.resources.progress(session: id, seconds: sample.seconds, peak: sample.peak)
        }
        let submissions = fixture.progressDispatcher.takeSubmissions()
        XCTAssertEqual(submissions.count, 2)
        XCTAssertEqual(Set(submissions.map(\.ordinal)).count, 2)
        XCTAssertTrue(publications.isEmpty)
        for submission in submissions.reversed() {
            guard await awaitProgressTask(submission) else { return }
        }
        // Exact handles, not queue FIFO, establish both completions.
        XCTAssertEqual(publications.sorted { $0.seconds < $1.seconds }, expected)
        await cancelAndDrain(fixture)
    }
}
