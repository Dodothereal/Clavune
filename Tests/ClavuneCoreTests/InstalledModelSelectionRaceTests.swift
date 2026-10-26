import Foundation
import XCTest
@testable import ClavuneApp
@testable import ClavuneCore

/// Source-only proposal against the isolated installed-model-selection candidate.
/// Controlled restore/unload boundaries; no real model, network, mic or file write.
final class InstalledModelSelectionRaceTests: UIFixtureAssertions {
    private struct ReviewSnapshot {
        let id: UUID
        let raw: String
        let utf8: Data
    }

    @MainActor private func preferences() throws -> (UserDefaults, String) {
        let suite = "Clavune.InstalledModelSelectionRaceTests." + UUID().uuidString
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    @MainActor private func makeReview(_ fixture: CoordinatorFixture, text: String) async throws -> ReviewSnapshot {
        await startRecording(fixture)
        await stopToReview(fixture)
        fixture.coordinator.editedText = text
        return ReviewSnapshot(id: try XCTUnwrap(fixture.coordinator.session.id),
                              raw: fixture.coordinator.session.rawTranscript,
                              utf8: Data(text.utf8))
    }

    @MainActor private func assertSameReview(_ fixture: CoordinatorFixture, _ expected: ReviewSnapshot,
                                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(fixture.coordinator.session.phase, .review, file: file, line: line)
        XCTAssertEqual(fixture.coordinator.session.id, expected.id, file: file, line: line)
        XCTAssertEqual(fixture.coordinator.session.rawTranscript, expected.raw, file: file, line: line)
        XCTAssertEqual(Data(fixture.coordinator.editedText.utf8), expected.utf8, file: file, line: line)
        XCTAssertEqual(fixture.coordinator.microphone.state, .closed, file: file, line: line)
    }

    @MainActor func testDirtyReviewHeldInventoryCancelOrPrivacyDoesNotPublishPartialResults() async throws {
        for usePrivacy in [false, true] {
            let (defaults, suite) = try preferences()
            defer { defaults.removePersistentDomain(forName: suite) }
            let previous = try XCTUnwrap(ModelStore.candidates().first)
            defaults.set(previous.sha256, forKey: "selectedModelSHA256")
            let entered = expectation(description: "Local scan entered")
            let release = DispatchSemaphore(value: 0)
            defer { release.signal() }
            let fixture = try CoordinatorFixture(preferences: defaults,
                restoreManagedSelection: { hash in
                    guard hash == previous.sha256 else { throw DictationError.modelInvalid }
                    entered.fulfill()
                    XCTAssertEqual(release.wait(timeout: .now() + 5), .success,
                                   "Fixture release must be explicit")
                    return ModelStore.Installed(url: URL(fileURLWithPath: "/synthetic-local-model"),
                                                candidate: previous)
                })
            let review = try await makeReview(fixture, text: "Unsent 🧪 review e\u{301}")
            fixture.coordinator.checkInstalledModels()
            await fulfillment(of: [entered], timeout: 2)
            let settled = expectation(description: "Cancelled inventory drained")
            fixture.observeOperationFinished(settled)
            if usePrivacy { fixture.coordinator.interruptForPrivacy() }
            else { fixture.coordinator.cancel() }
            assertSameReview(fixture, review)
            XCTAssertTrue(fixture.coordinator.hasUnsavedReview)
            XCTAssertTrue(fixture.coordinator.operationPending,
                          "Admission stays busy until the detached hash worker exits")
            XCTAssertFalse(fixture.coordinator.localModelInventoryChecked)
            XCTAssertTrue(fixture.coordinator.verifiedInstalledModelHashes.isEmpty)
            release.signal()
            await fulfillment(of: [settled], timeout: 2)
            assertSameReview(fixture, review)
            XCTAssertTrue(fixture.coordinator.hasUnsavedReview)
            XCTAssertFalse(fixture.coordinator.localModelInventoryChecked)
            XCTAssertTrue(fixture.coordinator.verifiedInstalledModelHashes.isEmpty)
            XCTAssertEqual(fixture.coordinator.model?.sha256, previous.sha256)
            XCTAssertEqual(defaults.string(forKey: "selectedModelSHA256"), previous.sha256)
            XCTAssertEqual(fixture.inference.counts.value.unloads, 0)
            XCTAssertEqual(fixture.terminationCalls, 0)
        }
    }

    @MainActor func testDirtyReviewQuitSaveWaitsForHeldSelectionReverificationAndRejectsLateSwitch() async throws {
        let (defaults, suite) = try preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let models = try ModelStore.candidates()
        let previous = try XCTUnwrap(models.first), candidate = try XCTUnwrap(models.dropFirst().first)
        defaults.set(previous.sha256, forKey: "selectedModelSHA256")
        let holdSelection = FixtureValue(false)
        let entered = expectation(description: "Selection restore entered")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        var confirmations = 0, savePickers = 0
        let writes = FixtureValue<[Data]>([]), downloads = FixtureValue(0)
        let fixture = try CoordinatorFixture(preferences: defaults,
            configureEnvironment: { environment in
                environment.confirmUnsavedReviewQuit = { _ in confirmations += 1; return .save }
                environment.chooseTranscriptToSave = { _ in
                    savePickers += 1
                    return URL(fileURLWithPath: "/synthetic-quit-save-never-opened.txt")
                }
                environment.writeTranscript = { text, _ in writes.update { $0.append(Data(text.utf8)) } }
                environment.downloadManagedModel = { _, _ in
                    downloads.update { $0 += 1 }
                    throw ModelDownloadFailure.unavailableSource
                }
            }, restoreManagedSelection: { hash in
                if hash == previous.sha256 {
                    return ModelStore.Installed(url: URL(fileURLWithPath: "/fixture-model-never-opened"),
                                                candidate: previous)
                }
                guard hash == candidate.sha256 else { throw DictationError.modelInvalid }
                if holdSelection.value {
                    entered.fulfill()
                    XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
                }
                return ModelStore.Installed(url: URL(fileURLWithPath: "/synthetic-local-model"),
                                            candidate: candidate)
            })
        let review = try await makeReview(fixture, text: "Exact dirty review 🪄 e\u{301}\n")
        fixture.coordinator.checkInstalledModels()
        let checked = expectation(description: "Inventory settled")
        fixture.observeOperationFinished(checked)
        await fulfillment(of: [checked], timeout: 2)
        XCTAssertTrue(fixture.coordinator.verifiedInstalledModelHashes.contains(candidate.sha256))
        holdSelection.value = true
        fixture.coordinator.selectInstalledModel(candidate)
        await fulfillment(of: [entered], timeout: 2)
        fixture.terminated = expectation(description: "Quit Save terminated after selection drain")
        fixture.coordinator.quit()
        assertSameReview(fixture, review)
        XCTAssertEqual(confirmations, 1)
        XCTAssertEqual(savePickers, 0, "Save panel must await admitted verification")
        XCTAssertTrue(writes.value.isEmpty)
        XCTAssertEqual(fixture.terminationCalls, 0)
        XCTAssertTrue(fixture.coordinator.operationPending)
        XCTAssertEqual(fixture.coordinator.model?.sha256, previous.sha256)
        XCTAssertEqual(defaults.string(forKey: "selectedModelSHA256"), previous.sha256)
        release.signal()
        await fulfillment(of: [try XCTUnwrap(fixture.terminated)], timeout: 2)
        assertSameReview(fixture, review)
        XCTAssertEqual(savePickers, 1)
        XCTAssertEqual(writes.value, [review.utf8])
        XCTAssertEqual(fixture.coordinator.model?.sha256, previous.sha256)
        XCTAssertEqual(defaults.string(forKey: "selectedModelSHA256"), previous.sha256)
        XCTAssertEqual(downloads.value, 0)
        XCTAssertFalse(fixture.coordinator.hasUnsavedReview)
        XCTAssertEqual(fixture.terminationCalls, 1)
    }

    @MainActor func testCancelDuringSuspendedSelectionUnloadRejectsLateSwitchAndKeepsReview() async throws {
        let (defaults, suite) = try preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let models = try ModelStore.candidates()
        let previous = try XCTUnwrap(models.first), candidate = try XCTUnwrap(models.dropFirst().first)
        defaults.set(previous.sha256, forKey: "selectedModelSHA256")
        let fixture = try CoordinatorFixture(preferences: defaults,
            restoreManagedSelection: { hash in
                if hash == previous.sha256 {
                    return ModelStore.Installed(url: URL(fileURLWithPath: "/fixture-model-never-opened"),
                                                candidate: previous)
                }
                guard hash == candidate.sha256 else { throw DictationError.modelInvalid }
                return ModelStore.Installed(url: URL(fileURLWithPath: "/synthetic-local-model"),
                                            candidate: candidate)
            })
        let review = try await makeReview(fixture, text: "Unsent while unload waits")
        fixture.coordinator.checkInstalledModels()
        let checked = expectation(description: "Inventory settled")
        fixture.observeOperationFinished(checked)
        await fulfillment(of: [checked], timeout: 2)
        let unload = ControlledDelivery(), unloadEntered = expectation(description: "Selection unload entered")
        fixture.inference.unloadGate = unload; fixture.inference.onUnload = unloadEntered
        fixture.coordinator.selectInstalledModel(candidate)
        await fulfillment(of: [unloadEntered], timeout: 2)
        await unload.waitUntilSuspended()
        let settled = expectation(description: "Cancelled selection unload drained")
        fixture.observeOperationFinished(settled)
        fixture.coordinator.cancel()
        assertSameReview(fixture, review)
        XCTAssertTrue(fixture.coordinator.hasUnsavedReview)
        XCTAssertTrue(fixture.coordinator.operationPending)
        XCTAssertEqual(fixture.coordinator.model?.sha256, previous.sha256)
        XCTAssertEqual(defaults.string(forKey: "selectedModelSHA256"), previous.sha256)
        XCTAssertEqual(fixture.terminationCalls, 0)
        await unload.release()
        await fulfillment(of: [settled], timeout: 2)
        assertSameReview(fixture, review)
        XCTAssertEqual(fixture.coordinator.model?.sha256, previous.sha256)
        XCTAssertEqual(defaults.string(forKey: "selectedModelSHA256"), previous.sha256)
        XCTAssertEqual(fixture.terminationCalls, 0)
    }

    @MainActor func testQuitSaveDuringSuspendedSelectionUnloadWaitsBeforeSavingAndSwitchNeverPublishes() async throws {
        let (defaults, suite) = try preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let models = try ModelStore.candidates()
        let previous = try XCTUnwrap(models.first), candidate = try XCTUnwrap(models.dropFirst().first)
        defaults.set(previous.sha256, forKey: "selectedModelSHA256")
        var savePickers = 0
        let writes = FixtureValue<[Data]>([])
        let fixture = try CoordinatorFixture(preferences: defaults,
            configureEnvironment: { environment in
                environment.confirmUnsavedReviewQuit = { _ in .save }
                environment.chooseTranscriptToSave = { _ in
                    savePickers += 1
                    return URL(fileURLWithPath: "/synthetic-quit-save-never-opened.txt")
                }
                environment.writeTranscript = { text, _ in writes.update { $0.append(Data(text.utf8)) } }
            }, restoreManagedSelection: { hash in
                if hash == previous.sha256 {
                    return ModelStore.Installed(url: URL(fileURLWithPath: "/fixture-model-never-opened"),
                                                candidate: previous)
                }
                guard hash == candidate.sha256 else { throw DictationError.modelInvalid }
                return ModelStore.Installed(url: URL(fileURLWithPath: "/synthetic-local-model"),
                                            candidate: candidate)
            })
        let review = try await makeReview(fixture, text: "Review while selection unload drains 🧪")
        fixture.coordinator.checkInstalledModels()
        let checked = expectation(description: "Inventory settled")
        fixture.observeOperationFinished(checked)
        await fulfillment(of: [checked], timeout: 2)
        let unload = ControlledDelivery(), unloadEntered = expectation(description: "Selection unload entered")
        fixture.inference.unloadGate = unload; fixture.inference.onUnload = unloadEntered
        fixture.coordinator.selectInstalledModel(candidate)
        await fulfillment(of: [unloadEntered], timeout: 2)
        await unload.waitUntilSuspended()
        fixture.terminated = expectation(description: "Quit terminated after unload and save")
        fixture.coordinator.quit()
        assertSameReview(fixture, review)
        XCTAssertEqual(savePickers, 0)
        XCTAssertTrue(writes.value.isEmpty)
        XCTAssertTrue(fixture.coordinator.operationPending)
        XCTAssertEqual(fixture.terminationCalls, 0)
        XCTAssertEqual(fixture.coordinator.model?.sha256, previous.sha256)
        XCTAssertEqual(defaults.string(forKey: "selectedModelSHA256"), previous.sha256)
        // The already-suspended selection unload holds this gate. Keep the final
        // Quit unload independent, then release the held call so drain can finish.
        fixture.inference.unloadGate = nil; fixture.inference.onUnload = nil
        await unload.release()
        await fulfillment(of: [try XCTUnwrap(fixture.terminated)], timeout: 2)
        assertSameReview(fixture, review)
        XCTAssertEqual(savePickers, 1)
        XCTAssertEqual(writes.value, [review.utf8])
        XCTAssertEqual(fixture.coordinator.model?.sha256, previous.sha256)
        XCTAssertEqual(defaults.string(forKey: "selectedModelSHA256"), previous.sha256)
        XCTAssertFalse(fixture.coordinator.hasUnsavedReview)
        XCTAssertEqual(fixture.terminationCalls, 1)
    }
}
