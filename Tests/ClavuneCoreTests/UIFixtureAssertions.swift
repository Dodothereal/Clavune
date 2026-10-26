import Combine
import XCTest
@testable import ClavuneApp
@testable import ClavuneCore

/// Real AppCoordinator + CaptureService, with only resource callbacks and fake delivery controlled.
class UIFixtureAssertions: XCTestCase {
    @MainActor func startRecording(_ fixture: CoordinatorFixture) async {
        let recording = expectation(description: "coordinator entered recording")
        let finished = expectation(description: "startup task settled")
        fixture.coordinator.start()
        fixture.observePhase(.recording, expectation: recording)
        fixture.observeOperationFinished(finished)
        await fulfillment(of: [recording, finished], timeout: 2)
        XCTAssertEqual(fixture.coordinator.microphone.state, .recording)
    }

    @MainActor func waitForOperation(_ fixture: CoordinatorFixture) async {
        let finished = expectation(description: "admitted task settled")
        fixture.observeOperationFinished(finished)
        await fulfillment(of: [finished], timeout: 2)
    }

    @MainActor func cancelAndDrain(_ fixture: CoordinatorFixture) async {
        fixture.coordinator.cancel()
        let closed = expectation(description: "service acknowledged close")
        fixture.observeCloseFinished(closed)
        await fulfillment(of: [closed], timeout: 2)
        await waitForOperation(fixture)
        XCTAssertEqual(fixture.coordinator.microphone.state, .closed)
    }

    @MainActor func stopToReview(_ fixture: CoordinatorFixture) async {
        let reviewed = expectation(description: "synthetic decode accepted")
        fixture.observePhase(.review, expectation: reviewed)
        fixture.coordinator.stop()
        await fulfillment(of: [reviewed], timeout: 2)
        await waitForOperation(fixture)
    }

    @MainActor func awaitProgressTask(_ submission: FixtureProgressDispatcher.Submission,
                                      file: StaticString = #filePath, line: UInt = #line) async -> Bool {
        let completed = expectation(description: "exact MainActor progress task completed: \(submission.ordinal)")
        // Acknowledge outside the supplied body: all early-return paths still complete task.value.
        let waiter = Task {
            await submission.task.value
            completed.fulfill()
        }
        let result = await XCTWaiter.fulfillment(of: [completed], timeout: 2)
        guard result == .completed else {
            waiter.cancel()
            XCTFail("Progress task completion timeout is invalid evidence, not callback rejection", file: file, line: line)
            return false
        }
        await waiter.value
        return true
    }

    @MainActor func completeProgress(_ fixture: CoordinatorFixture, session: UUID,
                                     seconds: Double, peak: Float,
                                     file: StaticString = #filePath, line: UInt = #line) async -> Bool {
        guard fixture.resources.callbacks.value[session] != nil else {
            XCTFail("No production callback captured", file: file, line: line)
            return false
        }
        let preceding = fixture.progressDispatcher.takeSubmissions()
        guard preceding.isEmpty else {
            XCTFail("Unacknowledged earlier progress tasks cannot stand in for this invocation", file: file, line: line)
            return false
        }
        fixture.resources.progress(session: session, seconds: seconds, peak: peak)
        let submissions = fixture.progressDispatcher.takeSubmissions()
        guard submissions.count == 1, let submission = submissions.first else {
            XCTFail("Each actual production callback must schedule exactly one retained task", file: file, line: line)
            return false
        }
        return await awaitProgressTask(submission, file: file, line: line)
    }

    @MainActor func acceptProgress(_ fixture: CoordinatorFixture, session: UUID,
                                   seconds: Double, peak: Float) async {
        let sample = CapturePresentationSample(seconds: seconds, peak: peak)
        var publications: [CapturePresentationSample] = []
        let observation = fixture.coordinator.capturePresentation.$sample.dropFirst()
            .sink { publications.append($0) }
        defer { observation.cancel() }
        guard await completeProgress(fixture, session: session, seconds: seconds, peak: peak) else { return }
        XCTAssertEqual(publications, [sample], "Completed production callback must publish the exact pair once")
        XCTAssertEqual(fixture.coordinator.capturePresentation.sample, sample)
    }

    @MainActor func rejectProgress(_ fixture: CoordinatorFixture, session: UUID,
                                   seconds: Double = 91.125, peak: Float = 0.9375) async {
        let before = fixture.coordinator.capturePresentation.sample
        let microphone = fixture.coordinator.microphone
        var publications = 0
        let observation = fixture.coordinator.capturePresentation.$sample.dropFirst()
            .sink { _ in publications += 1 }
        defer { observation.cancel() }
        guard await completeProgress(fixture, session: session, seconds: seconds, peak: peak) else { return }
        XCTAssertEqual(publications, 0, "Completed production progress callback published unexpectedly")
        XCTAssertEqual(fixture.coordinator.capturePresentation.sample, before,
            "Stale production callback overwrote the current presentation")
        XCTAssertEqual(fixture.coordinator.microphone.state, microphone.state)
    }

    @MainActor func assertHotkeyEnableIgnored(_ fixture: CoordinatorFixture,
                                             file: StaticString = #filePath, line: UInt = #line) {
        let enabled = fixture.coordinator.hotkeyEnabled
        let hold = fixture.coordinator.holdToTalk
        let shortcut = fixture.coordinator.developmentShortcut
        let attempts = fixture.hotkeyRegistrar.shortcuts.count
        let active = fixture.hotkeyRegistrar.activeCount
        let unregisters = fixture.hotkeyRegistrar.registrations.map(\.unregisterCalls)
        fixture.coordinator.setHotkeyEnabled(!enabled)
        XCTAssertEqual(fixture.coordinator.hotkeyEnabled, enabled, file: file, line: line)
        XCTAssertEqual(fixture.coordinator.holdToTalk, hold, file: file, line: line)
        XCTAssertEqual(fixture.coordinator.developmentShortcut, shortcut, file: file, line: line)
        XCTAssertEqual(fixture.hotkeyRegistrar.shortcuts.count, attempts, file: file, line: line)
        XCTAssertEqual(fixture.hotkeyRegistrar.activeCount, active, file: file, line: line)
        XCTAssertEqual(fixture.hotkeyRegistrar.registrations.map(\.unregisterCalls), unregisters, file: file, line: line)
    }
}
