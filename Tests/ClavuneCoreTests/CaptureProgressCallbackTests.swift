import Combine
import XCTest
@testable import ClavuneApp
@testable import ClavuneCore

/// These tests invoke captured production onProgress closures, never assign session/leaf state.
final class CaptureProgressCallbackTests: UIFixtureAssertions {
    @MainActor func testPreparingStartingAcceptsProgressWithoutClaimingFirstSample() async throws {
        let fixture = try CoordinatorFixture()
        fixture.resources.automaticallyDeliverFirstSample = false
        fixture.coordinator.start()
        await waitForOperation(fixture)
        let id = try XCTUnwrap(fixture.coordinator.session.id)
        XCTAssertEqual(fixture.coordinator.session.phase, .preparing)
        XCTAssertEqual(fixture.coordinator.microphone.state, .starting)
        XCTAssertTrue(fixture.coordinator.canStop, "A real capture in preparation can be stopped")
        await acceptProgress(fixture, session: id, seconds: 0.125, peak: 0.875)
        XCTAssertEqual(fixture.coordinator.session.phase, .preparing)
        XCTAssertEqual(fixture.coordinator.microphone.state, .starting,
            "A meter value cannot acknowledge microphone readiness")
        let recorded = expectation(description: "real first-sample callback drives recording")
        fixture.observePhase(.recording, expectation: recorded)
        fixture.resources.firstSample(session: id)
        await fulfillment(of: [recorded], timeout: 2)
        XCTAssertEqual(fixture.coordinator.microphone.state, .recording)
        XCTAssertTrue(fixture.coordinator.canStop, "Stop remains available while recording")
        await cancelAndDrain(fixture)
        XCTAssertFalse(fixture.coordinator.canStop)
    }

    @MainActor func testRecordingForwardsExactPairsToLeafWithoutPublishingCoordinator() async throws {
        let fixture = try CoordinatorFixture()
        await startRecording(fixture)
        let id = try XCTUnwrap(fixture.coordinator.session.id)
        var coordinatorChanges = 0
        var samples: [CapturePresentationSample] = []
        let parent = fixture.coordinator.objectWillChange.sink { coordinatorChanges += 1 }
        let child = fixture.coordinator.capturePresentation.$sample.dropFirst().sink { samples.append($0) }
        let expected = [CapturePresentationSample(seconds: 0.125, peak: 0.875),
                        CapturePresentationSample(seconds: 0.225, peak: 0.875),
                        CapturePresentationSample(seconds: 0.225, peak: 0.25),
                        CapturePresentationSample(seconds: 0.325, peak: 1)]
        for pair in expected {
            await acceptProgress(fixture, session: id, seconds: pair.seconds, peak: pair.peak)
        }
        XCTAssertEqual(samples, expected, "Changed elapsed OR changed peak must publish the exact pair")
        XCTAssertEqual(coordinatorChanges, 0, "Progress leaf must not forward updates to the root coordinator")
        // An identical producer callback must not cause a second child publication.
        await rejectProgress(fixture, session: id, seconds: 0.325, peak: 1)
        XCTAssertEqual(samples, expected)
        XCTAssertEqual(coordinatorChanges, 0)
        parent.cancel(); child.cancel()
        await cancelAndDrain(fixture)
    }

    @MainActor func testStoppingClosingAcceptsFinalProgressThenTranscribingRejectsLatePeak() async throws {
        let fixture = try CoordinatorFixture()
        await startRecording(fixture)
        let id = try XCTUnwrap(fixture.coordinator.session.id)
        await acceptProgress(fixture, session: id, seconds: 2, peak: 0.5)
        let submitted = expectation(description: "production stop queued but not executed")
        fixture.queue.pause(nextSubmission: submitted)
        let gate = ControlledDelivery()
        fixture.inference.decodeGate = gate
        fixture.coordinator.stop()
        await fulfillment(of: [submitted], timeout: 2)
        XCTAssertEqual(fixture.coordinator.session.phase, .stopping)
        XCTAssertEqual(fixture.coordinator.microphone.state, .closing)
        await acceptProgress(fixture, session: id, seconds: 2.125, peak: 0.75)
        XCTAssertEqual(fixture.coordinator.microphone.state, .closing)
        fixture.queue.resume()
        await gate.waitUntilSuspended()
        XCTAssertEqual(fixture.coordinator.session.phase, .transcribing)
        XCTAssertEqual(fixture.coordinator.microphone.state, .closed)
        XCTAssertEqual(fixture.coordinator.capturePresentation.sample,
                       CapturePresentationSample(seconds: 2.125, peak: 0))
        await rejectProgress(fixture, session: id)
        let reviewed = expectation(description: "delayed fake decode returns")
        fixture.observePhase(.review, expectation: reviewed)
        await gate.release()
        await fulfillment(of: [reviewed], timeout: 2)
        await waitForOperation(fixture)
        await rejectProgress(fixture, session: id)
        fixture.coordinator.discard()
        XCTAssertEqual(fixture.coordinator.session.phase, .idle)
        await rejectProgress(fixture, session: id)
    }

    @MainActor func testFailedSameSessionRejectsRetainedProductionProgress() async throws {
        let fixture = try CoordinatorFixture()
        fixture.resources.failDuringOpen = true
        fixture.coordinator.start()
        let id = try XCTUnwrap(fixture.coordinator.session.id)
        await waitForOperation(fixture)
        XCTAssertEqual(fixture.coordinator.session.phase, .failed)
        XCTAssertEqual(fixture.coordinator.session.id, id,
            "Same-session terminal oracle must not pass only because the session ID changed")
        XCTAssertEqual(fixture.coordinator.microphone.state, .closed)
        XCTAssertEqual(fixture.resources.counts.value.closed, 1)
        await rejectProgress(fixture, session: id)
    }

    @MainActor func testCancelledAndPriorSessionCallbacksCannotOverwriteNewSession() async throws {
        let fixture = try CoordinatorFixture()
        await startRecording(fixture)
        let first = try XCTUnwrap(fixture.coordinator.session.id)
        await acceptProgress(fixture, session: first, seconds: 3.25, peak: 0.75)
        await cancelAndDrain(fixture)
        XCTAssertEqual(fixture.coordinator.session.phase, .cancelled)
        XCTAssertEqual(fixture.coordinator.capturePresentation.sample,
                       CapturePresentationSample(seconds: 3.25, peak: 0))
        await rejectProgress(fixture, session: first)
        await startRecording(fixture)
        let second = try XCTUnwrap(fixture.coordinator.session.id)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(fixture.coordinator.capturePresentation.sample, CapturePresentationSample())
        await acceptProgress(fixture, session: second, seconds: 0.125, peak: 0.125)
        await rejectProgress(fixture, session: first)
        XCTAssertEqual(fixture.coordinator.session.id, second)
        XCTAssertEqual(fixture.coordinator.microphone.state, .recording)
        await acceptProgress(fixture, session: second, seconds: 0.225, peak: 0.5)
        await cancelAndDrain(fixture)
    }
}
