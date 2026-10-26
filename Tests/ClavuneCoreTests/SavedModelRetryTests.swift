import Foundation
import XCTest
@testable import ClavuneApp
@testable import ClavuneCore

/// Synthetic verification only. No production model folder, inference or microphone.
final class SavedModelRetryTests: UIFixtureAssertions {
    @MainActor private func preferences() throws -> (UserDefaults, String) {
        let suite = "Clavune.SavedModelRetryTests." + UUID().uuidString
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    @MainActor func testRetryFailureThenSuccessAndDuplicateAdmission() async throws {
        let (defaults, suite) = try preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let candidate = try XCTUnwrap(ModelStore.candidates().first)
        defaults.set(candidate.sha256, forKey: "selectedModelSHA256")
        let calls = FixtureValue<[String]>([])
        let succeeds = FixtureValue(false)
        let fixture = try CoordinatorFixture(preferences: defaults, modelSelectionEnabled: false,
            restoreManagedSelection: { hash in
                XCTAssertFalse(Thread.isMainThread)
                calls.update { $0.append(hash) }
                guard succeeds.value else { throw DictationError.modelInvalid }
                return ModelStore.Installed(url: URL(fileURLWithPath: "/synthetic-never-opened"), candidate: candidate)
            })
        XCTAssertTrue(fixture.coordinator.canRestoreManagedModel)
        for success in [false, true] {
            succeeds.value = success
            fixture.coordinator.restoreManagedModel()
            XCTAssertFalse(fixture.coordinator.canRestoreManagedModel)
            fixture.coordinator.restoreManagedModel()
            let done = expectation(description: "Verification settled")
            fixture.observeOperationFinished(done)
            await fulfillment(of: [done], timeout: 2)
            XCTAssertEqual(fixture.coordinator.model != nil, success)
            XCTAssertEqual(fixture.coordinator.canRestoreManagedModel, !success)
        }
        XCTAssertEqual(calls.value, [candidate.sha256, candidate.sha256])
        XCTAssertEqual(defaults.string(forKey: "selectedModelSHA256"), candidate.sha256)
        XCTAssertEqual(fixture.inference.counts.value.loads, 0)
        XCTAssertEqual(fixture.resources.counts.value.opened, 0)
    }

    @MainActor func testCancellationDrainsAndRejectsLateSuccessfulResultThenAllowsRetry() async throws {
        try await interruptedVerification(quit: false)
    }
    @MainActor func testQuitWaitsForVerificationAndRejectsLateSuccessfulResult() async throws {
        try await interruptedVerification(quit: true)
    }
    @MainActor private func interruptedVerification(quit: Bool) async throws {
        let (defaults, suite) = try preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let candidate = try XCTUnwrap(ModelStore.candidates().first)
        defaults.set(candidate.sha256, forKey: "selectedModelSHA256")
        let entered = expectation(description: "Detached verifier entered")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let wasCancelled = FixtureValue(false)
        let calls = FixtureValue(0)
        let fixture = try CoordinatorFixture(preferences: defaults, modelSelectionEnabled: false,
            restoreManagedSelection: { _ in
                calls.update { $0 += 1 }
                if calls.value == 1 {
                    entered.fulfill()
                    // Bounded fallback prevents a failed test stranding a worker.
                    _ = release.wait(timeout: .now() + 5)
                    wasCancelled.value = Task.isCancelled
                }
                return ModelStore.Installed(url: URL(fileURLWithPath: "/synthetic-never-opened"), candidate: candidate)
            })
        fixture.coordinator.restoreManagedModel()
        await fulfillment(of: [entered], timeout: 2)
        let settled = expectation(description: "Verification drained")
        fixture.observeOperationFinished(settled)
        let closed = quit ? nil : expectation(description: "Close acknowledged")
        if quit {
            fixture.terminated = expectation(description: "Terminate after drain")
            fixture.quitWillAwaitAdmittedOperation = expectation(description: "Quit awaits verifier")
            fixture.coordinator.quit(); fixture.coordinator.quit()
            await fulfillment(of: [fixture.quitWillAwaitAdmittedOperation!], timeout: 2)
        } else {
            fixture.coordinator.cancel()
            fixture.observeCloseFinished(try XCTUnwrap(closed))
        }
        XCTAssertTrue(fixture.coordinator.operationPending)
        XCTAssertFalse(fixture.coordinator.canRestoreManagedModel)
        fixture.coordinator.restoreManagedModel()
        XCTAssertEqual(fixture.terminationCalls, 0)
        release.signal()
        await fulfillment(of: [settled], timeout: 2)
        if quit {
            await fulfillment(of: [fixture.terminated!], timeout: 2)
            XCTAssertEqual(fixture.terminationCalls, 1)
        } else {
            await fulfillment(of: [try XCTUnwrap(closed)], timeout: 2)
            XCTAssertTrue(fixture.coordinator.canRestoreManagedModel)
        }
        XCTAssertTrue(wasCancelled.value)
        XCTAssertNil(fixture.coordinator.model, "A cancelled verifier's successful return is stale")
        XCTAssertEqual(defaults.string(forKey: "selectedModelSHA256"), candidate.sha256)
        XCTAssertEqual(fixture.inference.counts.value.loads, 0)
        XCTAssertEqual(fixture.resources.counts.value.opened, 0)
        if !quit {
            fixture.coordinator.restoreManagedModel()
            let retried = expectation(description: "Actual retry succeeded after cancellation")
            fixture.observeOperationFinished(retried)
            await fulfillment(of: [retried], timeout: 2)
            XCTAssertEqual(calls.value, 2)
            XCTAssertEqual(fixture.coordinator.model?.sha256, candidate.sha256)
            XCTAssertEqual(fixture.coordinator.session.phase, .idle)
            XCTAssertEqual(fixture.coordinator.message, "Modell bereit. Mikrofon geschlossen.")
            XCTAssertEqual(fixture.coordinator.modelStatus,
                           candidate.fileName + " — Hash geprüft, Qualität noch ungemessen")
            XCTAssertTrue(fixture.coordinator.canStart)
            XCTAssertFalse(fixture.coordinator.canRestoreManagedModel)
            XCTAssertEqual(fixture.resources.counts.value.opened, 0)
            XCTAssertEqual(fixture.inference.counts.value.loads, 0)
        }
    }

    @MainActor func testNoSavedSelectionAndQARejectVerification() throws {
        let (defaults, suite) = try preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let calls = FixtureValue(0)
        let verify: @Sendable (String) throws -> ModelStore.Installed = { _ in
            calls.update { $0 += 1 }; throw DictationError.modelInvalid
        }
        // Check the complete lookup, not just the persistent suite: a leaked
        // registration fallback would mean this is not a missing-selection case.
        XCTAssertNil(defaults.object(forKey: "selectedModelSHA256"),
                     "Missing-selection fixture inherited a defaults fallback")
        let missing = try CoordinatorFixture(preferences: defaults, modelSelectionEnabled: false,
                                             restoreManagedSelection: verify)
        XCTAssertFalse(missing.coordinator.canRestoreManagedModel)
        missing.coordinator.restoreManagedModel()
        XCTAssertFalse(missing.coordinator.operationPending)
        XCTAssertEqual(calls.value, 0)
        let configuration = try AppLaunchConfiguration.parse(environment: ["CLAVUNE_QA_PROFILE": "retry-" + String(UUID().uuidString.prefix(20))])
        let qaSuite = try XCTUnwrap(configuration.preferenceSuite)
        let qaDefaults = try XCTUnwrap(UserDefaults(suiteName: qaSuite))
        defer { qaDefaults.removePersistentDomain(forName: qaSuite) }
        qaDefaults.set("saved-hash", forKey: "selectedModelSHA256")
        let qa = try CoordinatorFixture(preferences: qaDefaults, launchConfiguration: configuration,
            modelSelectionEnabled: false, restoreManagedSelection: verify)
        XCTAssertFalse(qa.coordinator.canRestoreManagedModel)
        qa.coordinator.restoreManagedModel()
        XCTAssertFalse(qa.coordinator.operationPending)
        XCTAssertEqual(calls.value, 0)
    }

    @MainActor func testRecordingAndReviewRejectRetryWithoutLosingDraft() async throws {
        let (defaults, suite) = try preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("saved-hash", forKey: "selectedModelSHA256")
        let fixture = try CoordinatorFixture(preferences: defaults)
        await startRecording(fixture)
        XCTAssertFalse(fixture.coordinator.canRestoreManagedModel)
        fixture.coordinator.restoreManagedModel()
        await stopToReview(fixture)
        fixture.coordinator.editedText = "Keep this review"
        let id = fixture.coordinator.session.id
        XCTAssertFalse(fixture.coordinator.canRestoreManagedModel)
        fixture.coordinator.restoreManagedModel()
        XCTAssertEqual(fixture.coordinator.session.id, id)
        XCTAssertEqual(fixture.coordinator.session.phase, .review)
        XCTAssertEqual(fixture.coordinator.editedText, "Keep this review")
        XCTAssertFalse(fixture.coordinator.operationPending)
    }
}
