import Foundation
import XCTest
@testable import ClavuneApp
@testable import ClavuneCore

/// Real coordinator cancellation/admission with injected model-operation results.
/// No network, model bytes, inference, microphone, picker UI or production defaults.
final class ModelOperationRetryTests: UIFixtureAssertions {
    private enum Action: Equatable, Sendable { case importModel, downloadModel }
    private enum Outcome: Equatable, Sendable { case success, failure, noOp, cancelAgain }

    @MainActor func testImportSuccessAfterCancellationKeepsFreshResult() async throws {
        try await exercise(.importModel, outcome: .success)
    }
    @MainActor func testImportFailureAfterCancellationKeepsRecoveryGuidance() async throws {
        try await exercise(.importModel, outcome: .failure)
    }
    @MainActor func testDownloadSuccessAfterCancellationKeepsFreshResult() async throws {
        try await exercise(.downloadModel, outcome: .success)
    }
    @MainActor func testDownloadFailureAfterCancellationKeepsStorageGuidance() async throws {
        try await exercise(.downloadModel, outcome: .failure)
    }
    @MainActor func testCancelledPickerDoesNotErasePreviousCancellation() async throws {
        try await exercise(.importModel, outcome: .noOp)
    }
    @MainActor func testRejectedDownloadCandidateDoesNotErasePreviousCancellation() async throws {
        try await exercise(.downloadModel, outcome: .noOp)
    }
    @MainActor func testCancellingFreshImportRetryStillWins() async throws {
        try await exercise(.importModel, outcome: .cancelAgain)
    }
    @MainActor func testCancellingFreshDownloadRetryStillWins() async throws {
        try await exercise(.downloadModel, outcome: .cancelAgain)
    }

    @MainActor func testNewModelActionsDoNotDiscardPendingReview() async throws {
        for action in [Action.importModel, .downloadModel] {
            let requested = try XCTUnwrap(ModelStore.candidates().last)
            let installed = ModelStore.Installed(
                url: URL(fileURLWithPath: "/synthetic-review-model-never-opened"), candidate: requested)
            let fixture = try CoordinatorFixture(configureEnvironment: { environment in
                environment.chooseTranscriptToOpen = { _ in URL(fileURLWithPath: "/synthetic-review-never-opened.txt") }
                environment.readTranscript = { _ in "synthetic original review" }
                environment.importManagedModel = { _ in installed }
                environment.downloadManagedModel = { _, _ in installed }
            })
            fixture.chooseModel = { URL(fileURLWithPath: "/synthetic-review-source-never-opened") }
            fixture.coordinator.openTranscript()
            await waitForOperation(fixture)
            fixture.coordinator.editedText = "synthetic edited review"
            let reviewID = try XCTUnwrap(fixture.coordinator.session.id)
            begin(action, fixture: fixture, candidate: requested)
            XCTAssertEqual(fixture.coordinator.session.phase, .review)
            await waitForOperation(fixture)
            XCTAssertEqual(fixture.coordinator.session.phase, .review)
            XCTAssertEqual(fixture.coordinator.session.id, reviewID)
            XCTAssertEqual(fixture.coordinator.session.rawTranscript, "synthetic original review")
            XCTAssertEqual(fixture.coordinator.editedText, "synthetic edited review")
            XCTAssertEqual(fixture.coordinator.model?.sha256, requested.sha256)
            XCTAssertEqual(fixture.resources.counts.value.opened, 0)
            XCTAssertEqual(fixture.inference.counts.value.loads, 0)
            XCTAssertEqual(fixture.permissionCalls, 0)
            XCTAssertTrue(fixture.clipboard.calls.isEmpty)
        }
    }

    @MainActor private func begin(_ action: Action, fixture: CoordinatorFixture,
                                  candidate: ModelCandidate) {
        switch action {
        case .importModel: fixture.coordinator.importModel()
        case .downloadModel: fixture.coordinator.downloadModel(candidate)
        }
    }

    @MainActor private func exercise(_ action: Action, outcome: Outcome) async throws {
        let suite = "Clavune.ModelOperationRetryTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let models = try ModelStore.candidates()
        let original = try XCTUnwrap(models.first), requested = try XCTUnwrap(models.last)
        XCTAssertNotEqual(original.sha256, requested.sha256)
        defaults.set(original.sha256, forKey: "selectedModelSHA256")
        let calls = FixtureValue(0)
        let cancelledWorkers = FixtureValue(0)
        let entered = expectation(description: "First model worker entered")
        let retryEntered = outcome == .cancelAgain
            ? expectation(description: "Fresh retry worker entered") : nil
        // Synchronous import runs detached; its bounded wait cannot strand a worker.
        let importRelease = DispatchSemaphore(value: 0)
        let downloadRelease = ModelRetryDelivery()
        defer {
            importRelease.signal()
            Task { await downloadRelease.release() }
        }
        let installed = ModelStore.Installed(
            url: URL(fileURLWithPath: "/synthetic-retry-model-never-opened"), candidate: requested)
        let fixture = try CoordinatorFixture(preferences: defaults, configureEnvironment: { environment in
            environment.importManagedModel = { _ in
                XCTAssertFalse(Thread.isMainThread)
                calls.update { $0 += 1 }
                let call = calls.value
                if call == 1 || outcome == .cancelAgain {
                    if call == 1 { entered.fulfill() } else { retryEntered?.fulfill() }
                    XCTAssertEqual(importRelease.wait(timeout: .now() + 5), .success,
                                   "A timed-out gate is not a completed cancellation interleaving")
                    if Task.isCancelled { cancelledWorkers.update { $0 += 1 } }
                }
                if call > 1, outcome == .failure { throw ModelStore.RecoveryError.backupAlreadyExists }
                return installed // Deliberately stale success when this worker was cancelled.
            }
            environment.downloadManagedModel = { _, _ in
                calls.update { $0 += 1 }
                let call = calls.value
                if call == 1 || outcome == .cancelAgain {
                    if call == 1 { entered.fulfill() } else { retryEntered?.fulfill() }
                    await downloadRelease.suspend()
                    if Task.isCancelled { cancelledWorkers.update { $0 += 1 } }
                }
                if call > 1, outcome == .failure { throw ModelDownloadFailure.insufficientStorage }
                return installed
            }
        })
        fixture.chooseModel = { URL(fileURLWithPath: "/synthetic-retry-source-never-opened") }
        fixture.coordinator.uiLanguage = .german

        begin(action, fixture: fixture, candidate: requested)
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertTrue(fixture.coordinator.busy)
        begin(action, fixture: fixture, candidate: requested)
        XCTAssertEqual(calls.value, 1, "Busy admission must not start another worker")
        let firstFinished = expectation(description: "First cancelled model worker drained")
        fixture.observeOperationFinished(firstFinished)
        fixture.coordinator.cancel()
        let firstClosed = expectation(description: "First cancellation close acknowledged")
        fixture.observeCloseFinished(firstClosed)
        importRelease.signal()
        await downloadRelease.release()
        await fulfillment(of: [firstFinished, firstClosed], timeout: 3)
        XCTAssertFalse(fixture.coordinator.busy)
        XCTAssertEqual(cancelledWorkers.value, 1)
        XCTAssertEqual(fixture.coordinator.session.phase, .cancelled)
        XCTAssertEqual(fixture.coordinator.message, "Abgebrochen. Mikrofon geschlossen.")
        XCTAssertEqual(fixture.coordinator.model?.sha256, original.sha256)
        XCTAssertEqual(defaults.string(forKey: "selectedModelSHA256"), original.sha256)

        if outcome == .noOp {
            let message = fixture.coordinator.message, status = fixture.coordinator.modelStatus
            if action == .importModel {
                fixture.chooseModel = { nil }
                fixture.coordinator.importModel()
                XCTAssertEqual(fixture.pickerCalls, 2)
            } else {
                let disabled = ModelCandidate(fileName: requested.fileName, sizeBytes: requested.sizeBytes,
                    sha256: requested.sha256, role: requested.role, license: requested.license,
                    qualityGate: requested.qualityGate, sourceURL: requested.sourceURL,
                    sourceRevision: requested.sourceRevision, downloadEnabled: false)
                fixture.coordinator.downloadModel(disabled)
                let altered = ModelCandidate(fileName: requested.fileName, sizeBytes: requested.sizeBytes - 1,
                    sha256: requested.sha256, role: requested.role, license: requested.license,
                    qualityGate: requested.qualityGate, sourceURL: requested.sourceURL,
                    sourceRevision: requested.sourceRevision, downloadEnabled: true)
                fixture.coordinator.downloadModel(altered)
            }
            XCTAssertFalse(fixture.coordinator.busy)
            XCTAssertEqual(fixture.coordinator.session.phase, .cancelled)
            XCTAssertEqual(fixture.coordinator.message, message)
            XCTAssertEqual(fixture.coordinator.modelStatus, status)
            XCTAssertEqual(calls.value, 1)
        } else {
            begin(action, fixture: fixture, candidate: requested)
            XCTAssertEqual(fixture.coordinator.session.phase, .idle,
                           "An admitted retry must retire only the old terminal cancellation")
            let retried = expectation(description: "Fresh retry drained")
            fixture.observeOperationFinished(retried)
            if outcome == .cancelAgain {
                await fulfillment(of: [try XCTUnwrap(retryEntered)], timeout: 2)
                fixture.coordinator.cancel()
                let retryClosed = expectation(description: "Fresh cancellation close acknowledged")
                fixture.observeCloseFinished(retryClosed)
                importRelease.signal()
                await downloadRelease.release()
                await fulfillment(of: [retried, retryClosed], timeout: 3)
                XCTAssertEqual(cancelledWorkers.value, 2)
                XCTAssertEqual(fixture.coordinator.session.phase, .cancelled)
                XCTAssertEqual(fixture.coordinator.message, "Abgebrochen. Mikrofon geschlossen.")
            } else {
                await fulfillment(of: [retried], timeout: 3)
                XCTAssertEqual(fixture.coordinator.session.phase, .idle)
                if outcome == .success {
                    XCTAssertEqual(fixture.coordinator.message, "Modell bereit. Mikrofon geschlossen.")
                    XCTAssertEqual(fixture.coordinator.modelStatus,
                                   requested.fileName + " — Hash geprüft, Qualität noch ungemessen")
                    XCTAssertTrue(fixture.coordinator.canStart)
                } else if action == .importModel {
                    XCTAssertEqual(fixture.coordinator.message, ModelStore.RecoveryError.backupAlreadyExists.localizedDescription)
                    XCTAssertEqual(fixture.coordinator.modelStatus, "Import fehlgeschlagen")
                } else {
                    XCTAssertEqual(fixture.coordinator.message,
                        fixture.coordinator.uiLanguage.downloadFailureMessage(for: ModelDownloadFailure.insufficientStorage))
                    XCTAssertEqual(fixture.coordinator.modelStatus, "Modelldownload fehlgeschlagen")
                }
            }
            XCTAssertEqual(calls.value, 2)
        }
        let expected = outcome == .success ? requested : original
        XCTAssertEqual(fixture.coordinator.model?.sha256, expected.sha256)
        XCTAssertEqual(defaults.string(forKey: "selectedModelSHA256"), expected.sha256)
        XCTAssertEqual(fixture.coordinator.verifiedInstalledModelHashes.contains(requested.sha256), outcome == .success)
        XCTAssertEqual(fixture.inference.counts.value.unloads, outcome == .success ? 1 : 0)
        XCTAssertFalse(fixture.coordinator.operationPending)
        XCTAssertFalse(fixture.coordinator.closePending)
        XCTAssertFalse(fixture.coordinator.busy)
        XCTAssertEqual(fixture.coordinator.microphone.state, .closed)
        XCTAssertEqual(fixture.resources.counts.value.opened, 0)
        XCTAssertEqual(fixture.permissionCalls, 0)
        XCTAssertEqual(fixture.inference.counts.value.loads, 0)
        XCTAssertTrue(fixture.clipboard.calls.isEmpty)
    }
}

/// A one-credit gate makes release-before-suspend safe, without sleeps or polling.
private actor ModelRetryDelivery {
    private var credit = false
    private var continuation: CheckedContinuation<Void, Never>?
    func suspend() async {
        if credit { credit = false; return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        if let pending = continuation {
            continuation = nil; pending.resume()
        } else { credit = true }
    }
}
