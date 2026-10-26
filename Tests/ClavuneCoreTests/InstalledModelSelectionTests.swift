import Foundation
import XCTest
@testable import ClavuneApp
@testable import ClavuneCore

/// Synthetic coordinator coverage only; no real model files, network, mic or native UI run.
final class InstalledModelSelectionTests: UIFixtureAssertions {
    @MainActor private func preferences() throws -> (UserDefaults, String) {
        let suite = "Clavune.InstalledModelSelectionTests." + UUID().uuidString
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    @MainActor func testDeliberateLocalCheckThenSelectionDoesNotDownloadOrPromoteDefault() async throws {
        let (defaults, suite) = try preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let models = try ModelStore.candidates()
        XCTAssertGreaterThanOrEqual(models.count, 2)
        let candidate = models[1]
        let calls = FixtureValue<[String]>([])
        let downloadCalls = FixtureValue(0)
        let fixture = try CoordinatorFixture(preferences: defaults, modelSelectionEnabled: false,
            configureEnvironment: { environment in
                environment.downloadManagedModel = { _, _ in
                    downloadCalls.update { $0 += 1 }
                    throw ModelDownloadFailure.unavailableSource
                }
            }, restoreManagedSelection: { hash in
                XCTAssertFalse(Thread.isMainThread)
                calls.update { $0.append(hash) }
                guard hash == candidate.sha256 else { throw DictationError.modelInvalid }
                return ModelStore.Installed(url: URL(fileURLWithPath: "/synthetic-local-model"), candidate: candidate)
            })
        XCTAssertNil(defaults.string(forKey: "selectedModelSHA256"))
        XCTAssertFalse(fixture.coordinator.localModelInventoryChecked)
        fixture.coordinator.checkInstalledModels()
        let checked = expectation(description: "Explicit inventory check settled")
        fixture.observeOperationFinished(checked)
        await fulfillment(of: [checked], timeout: 2)
        XCTAssertEqual(calls.value, models.map(\.sha256))
        XCTAssertEqual(fixture.coordinator.verifiedInstalledModelHashes, Set([candidate.sha256]))
        XCTAssertTrue(fixture.coordinator.localModelInventoryChecked)
        XCTAssertNil(fixture.coordinator.model)
        XCTAssertNil(defaults.string(forKey: "selectedModelSHA256"))
        XCTAssertEqual(downloadCalls.value, 0)
        XCTAssertEqual(fixture.inference.counts.value.loads, 0)
        XCTAssertEqual(fixture.resources.counts.value.opened, 0)

        fixture.coordinator.selectInstalledModel(candidate)
        let selected = expectation(description: "Local selection settled")
        fixture.observeOperationFinished(selected)
        await fulfillment(of: [selected], timeout: 2)
        XCTAssertEqual(calls.value.filter { $0 == candidate.sha256 }.count, 2,
                       "Selection must reverify rather than trusting inventory")
        XCTAssertEqual(fixture.coordinator.model?.sha256, candidate.sha256)
        XCTAssertEqual(defaults.string(forKey: "selectedModelSHA256"), candidate.sha256)
        XCTAssertEqual(fixture.coordinator.message, "Lokales Modell ausgewählt. Kein Download. Mikrofon geschlossen.")
        XCTAssertEqual(downloadCalls.value, 0)
        XCTAssertEqual(fixture.inference.counts.value.loads, 0)
        XCTAssertEqual(fixture.resources.counts.value.opened, 0)
    }

    @MainActor func testDisappearingInstalledFileKeepsPreviousSelectionAndRemovesBadge() async throws {
        let (defaults, suite) = try preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let models = try ModelStore.candidates()
        XCTAssertGreaterThanOrEqual(models.count, 2)
        let previous = models[0], candidate = models[1]
        defaults.set(previous.sha256, forKey: "selectedModelSHA256")
        let available = FixtureValue(true)
        let calls = FixtureValue<[String]>([])
        let fixture = try CoordinatorFixture(preferences: defaults,
            restoreManagedSelection: { hash in
                calls.update { $0.append(hash) }
                if hash == previous.sha256 {
                    return ModelStore.Installed(url: URL(fileURLWithPath: "/fixture-model-never-opened"), candidate: previous)
                }
                guard hash == candidate.sha256, available.value else { throw DictationError.modelInvalid }
                return ModelStore.Installed(url: URL(fileURLWithPath: "/synthetic-local-model"), candidate: candidate)
            })
        fixture.coordinator.checkInstalledModels()
        let checked = expectation(description: "Inventory settled")
        fixture.observeOperationFinished(checked)
        await fulfillment(of: [checked], timeout: 2)
        XCTAssertTrue(fixture.coordinator.verifiedInstalledModelHashes.contains(candidate.sha256))
        available.value = false
        fixture.coordinator.selectInstalledModel(candidate)
        let selected = expectation(description: "Reverification failure settled")
        fixture.observeOperationFinished(selected)
        await fulfillment(of: [selected], timeout: 2)
        XCTAssertEqual(fixture.coordinator.model?.sha256, previous.sha256)
        XCTAssertTrue(fixture.coordinator.canStart)
        XCTAssertEqual(defaults.string(forKey: "selectedModelSHA256"), previous.sha256)
        XCTAssertFalse(fixture.coordinator.verifiedInstalledModelHashes.contains(candidate.sha256))
        XCTAssertEqual(calls.value.filter { $0 == candidate.sha256 }.count, 2)
        XCTAssertEqual(fixture.inference.counts.value.unloads, 0)
        XCTAssertEqual(fixture.resources.counts.value.opened, 0)
    }

    @MainActor func testSelectedFileInvalidOnExplicitCheckIsNotPresentedAsReady() async throws {
        let candidate = try XCTUnwrap(ModelStore.candidates().first)
        let available = FixtureValue(false)
        let fixture = try CoordinatorFixture(restoreManagedSelection: { hash in
            guard hash == candidate.sha256, available.value else { throw DictationError.modelInvalid }
            return ModelStore.Installed(url: URL(fileURLWithPath: "/fixture-model-never-opened"), candidate: candidate)
        })
        XCTAssertEqual(fixture.coordinator.model?.sha256, candidate.sha256)
        XCTAssertTrue(fixture.coordinator.canStart)
        fixture.coordinator.checkInstalledModels()
        let checked = expectation(description: "Invalid selected file check settled")
        fixture.observeOperationFinished(checked)
        await fulfillment(of: [checked], timeout: 2)
        XCTAssertTrue(fixture.coordinator.localModelInventoryChecked)
        XCTAssertFalse(fixture.coordinator.verifiedInstalledModelHashes.contains(candidate.sha256))
        XCTAssertFalse(fixture.coordinator.canStart, "A knowingly invalid selected file cannot remain Record-ready")
        XCTAssertEqual(DictationView(coordinator: fixture.coordinator).guidanceMode, .selectedModelUnavailable,
                       "Guidance must not tell the user to speak while Record is blocked")
        XCTAssertEqual(fixture.coordinator.model?.sha256, candidate.sha256,
                       "Do not silently replace the persisted user selection")
        XCTAssertEqual(fixture.coordinator.modelStatus,
                       "Ausgewähltes Modell lokal nicht mehr gültig oder nicht verfügbar")
        available.value = true
        fixture.coordinator.checkInstalledModels()
        let recovered = expectation(description: "Selected model reverified")
        fixture.observeOperationFinished(recovered)
        await fulfillment(of: [recovered], timeout: 2)
        XCTAssertTrue(fixture.coordinator.verifiedInstalledModelHashes.contains(candidate.sha256))
        XCTAssertTrue(fixture.coordinator.canStart)
        XCTAssertEqual(DictationView(coordinator: fixture.coordinator).guidanceMode, .ready)
        XCTAssertEqual(fixture.coordinator.modelStatus,
                       candidate.fileName + " — Hash geprüft, Qualität noch ungemessen")
    }

    @MainActor func testCancelHeldLocalSwitchPreservesDirtyReviewAndRejectsLateSuccess() async throws {
        let (defaults, suite) = try preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let models = try ModelStore.candidates()
        XCTAssertGreaterThanOrEqual(models.count, 2)
        let previous = models[0], candidate = models[1]
        defaults.set(previous.sha256, forKey: "selectedModelSHA256")
        let holdSelection = FixtureValue(false)
        let entered = expectation(description: "Reverification entered")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let fixture = try CoordinatorFixture(preferences: defaults,
            restoreManagedSelection: { hash in
                if hash == previous.sha256 {
                    return ModelStore.Installed(url: URL(fileURLWithPath: "/fixture-model-never-opened"), candidate: previous)
                }
                guard hash == candidate.sha256 else { throw DictationError.modelInvalid }
                if holdSelection.value {
                    entered.fulfill()
                    _ = release.wait(timeout: .now() + 5)
                }
                return ModelStore.Installed(url: URL(fileURLWithPath: "/synthetic-local-model"), candidate: candidate)
            })
        await startRecording(fixture)
        await stopToReview(fixture)
        fixture.coordinator.editedText = "Unsaved Unicode e\u{301} and 🪄"
        let reviewID = fixture.coordinator.session.id
        let raw = fixture.coordinator.session.rawTranscript
        fixture.coordinator.checkInstalledModels()
        let checked = expectation(description: "Inventory during review settled")
        fixture.observeOperationFinished(checked)
        await fulfillment(of: [checked], timeout: 2)
        XCTAssertTrue(fixture.coordinator.verifiedInstalledModelHashes.contains(candidate.sha256))
        holdSelection.value = true
        fixture.coordinator.selectInstalledModel(candidate)
        await fulfillment(of: [entered], timeout: 2)
        let settled = expectation(description: "Cancelled selection drained")
        fixture.observeOperationFinished(settled)
        fixture.coordinator.cancel()
        release.signal()
        await fulfillment(of: [settled], timeout: 2)
        XCTAssertEqual(fixture.coordinator.session.id, reviewID)
        XCTAssertEqual(fixture.coordinator.session.rawTranscript, raw)
        XCTAssertEqual(fixture.coordinator.editedText, "Unsaved Unicode e\u{301} and 🪄")
        XCTAssertTrue(fixture.coordinator.hasUnsavedReview)
        XCTAssertEqual(fixture.coordinator.model?.sha256, previous.sha256)
        XCTAssertEqual(defaults.string(forKey: "selectedModelSHA256"), previous.sha256)
        XCTAssertEqual(fixture.inference.counts.value.unloads, 0)
    }

    @MainActor func testCancelledCheckRejectsLateSuccessAndDoesNotSelect() async throws {
        let (defaults, suite) = try preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let candidate = try XCTUnwrap(ModelStore.candidates().first)
        let entered = expectation(description: "Detached local read entered")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let fixture = try CoordinatorFixture(preferences: defaults, modelSelectionEnabled: false,
            restoreManagedSelection: { _ in
                entered.fulfill()
                _ = release.wait(timeout: .now() + 5)
                return ModelStore.Installed(url: URL(fileURLWithPath: "/synthetic-local-model"), candidate: candidate)
            })
        fixture.coordinator.checkInstalledModels()
        await fulfillment(of: [entered], timeout: 2)
        let settled = expectation(description: "Cancelled check drained")
        fixture.observeOperationFinished(settled)
        fixture.coordinator.cancel()
        release.signal()
        await fulfillment(of: [settled], timeout: 2)
        XCTAssertFalse(fixture.coordinator.localModelInventoryChecked)
        XCTAssertTrue(fixture.coordinator.verifiedInstalledModelHashes.isEmpty)
        XCTAssertNil(fixture.coordinator.model)
        XCTAssertNil(defaults.string(forKey: "selectedModelSHA256"))
        XCTAssertEqual(fixture.resources.counts.value.opened, 0)
    }

    @MainActor func testFreshCheckAndSelectionAfterCancellationKeepTheirOwnResult() async throws {
        let candidate = try XCTUnwrap(ModelStore.candidates().first)
        let fixture = try CoordinatorFixture(modelSelectionEnabled: false,
            restoreManagedSelection: { hash in
                guard hash == candidate.sha256 else { throw DictationError.modelInvalid }
                return ModelStore.Installed(url: URL(fileURLWithPath: "/synthetic-local-model"),
                                            candidate: candidate)
            })

        fixture.coordinator.checkInstalledModels()
        XCTAssertTrue(fixture.coordinator.operationPending, "The operation to cancel must be admitted")
        guard fixture.coordinator.operationPending else { return }
        let cancelledCheck = expectation(description: "cancelled check drained")
        let closedCheck = expectation(description: "cancelled check closed")
        fixture.observeOperationFinished(cancelledCheck)
        fixture.coordinator.cancel()
        XCTAssertTrue(fixture.coordinator.closePending, "Cancel must admit the close before observation")
        guard fixture.coordinator.closePending else { return }
        // The publisher replays its current value. Observing before cancel()
        // would fulfill from the old false value, not this cancellation's drain.
        fixture.observeCloseFinished(closedCheck)
        await fulfillment(of: [cancelledCheck, closedCheck], timeout: 2)
        XCTAssertFalse(fixture.coordinator.operationPending)
        XCTAssertFalse(fixture.coordinator.closePending)
        XCTAssertFalse(fixture.coordinator.busy)
        guard !fixture.coordinator.operationPending, !fixture.coordinator.closePending,
              !fixture.coordinator.busy else { return }
        XCTAssertEqual(fixture.coordinator.session.phase, .cancelled)

        fixture.coordinator.checkInstalledModels()
        XCTAssertTrue(fixture.coordinator.operationPending, "The fresh check must be admitted")
        guard fixture.coordinator.operationPending else { return }
        let checked = expectation(description: "fresh check completed")
        fixture.observeOperationFinished(checked)
        await fulfillment(of: [checked], timeout: 2)
        XCTAssertEqual(fixture.coordinator.session.phase, .idle)
        XCTAssertTrue(fixture.coordinator.localModelInventoryChecked)
        XCTAssertTrue(fixture.coordinator.verifiedInstalledModelHashes.contains(candidate.sha256))
        XCTAssertEqual(fixture.coordinator.message,
                       "Lokale Modellprüfung abgeschlossen. Auswahl prüft die Datei erneut; kein Modelldownload.")

        fixture.coordinator.selectInstalledModel(candidate)
        XCTAssertTrue(fixture.coordinator.operationPending, "The selection to cancel must be admitted")
        guard fixture.coordinator.operationPending else { return }
        let cancelledSelection = expectation(description: "cancelled selection drained")
        let closedSelection = expectation(description: "cancelled selection closed")
        fixture.observeOperationFinished(cancelledSelection)
        fixture.coordinator.cancel()
        XCTAssertTrue(fixture.coordinator.closePending, "Cancel must admit the close before observation")
        guard fixture.coordinator.closePending else { return }
        fixture.observeCloseFinished(closedSelection)
        await fulfillment(of: [cancelledSelection, closedSelection], timeout: 2)
        XCTAssertFalse(fixture.coordinator.operationPending)
        XCTAssertFalse(fixture.coordinator.closePending)
        XCTAssertFalse(fixture.coordinator.busy)
        guard !fixture.coordinator.operationPending, !fixture.coordinator.closePending,
              !fixture.coordinator.busy else { return }
        XCTAssertEqual(fixture.coordinator.session.phase, .cancelled)
        XCTAssertNil(fixture.coordinator.model)

        fixture.coordinator.selectInstalledModel(candidate)
        XCTAssertTrue(fixture.coordinator.operationPending, "The fresh selection must be admitted")
        guard fixture.coordinator.operationPending else { return }
        let selected = expectation(description: "fresh selection completed")
        fixture.observeOperationFinished(selected)
        await fulfillment(of: [selected], timeout: 2)
        XCTAssertEqual(fixture.coordinator.session.phase, .idle)
        XCTAssertEqual(fixture.coordinator.model?.sha256, candidate.sha256)
        XCTAssertEqual(fixture.coordinator.message,
                       "Lokales Modell ausgewählt. Kein Download. Mikrofon geschlossen.")
        XCTAssertEqual(fixture.inference.counts.value.loads, 0)
        XCTAssertEqual(fixture.resources.counts.value.opened, 0)
    }
}
