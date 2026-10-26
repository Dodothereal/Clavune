import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import ClavuneApp
@testable import ClavuneCore

/// Real coordinator decisions with synthetic resources and deliberately selected
/// temporary text files. No live panels, process exit, microphone or clipboard.
final class UnsavedReviewQuitTests: UIFixtureAssertions {
    private let selected = URL(fileURLWithPath: "/synthetic-quit-transcript-never-opened.txt")

    private struct Review {
        let id: UUID?
        let raw: String
        let edited: String
        let metricsID: UUID?
    }

    private final class HeldWork: @unchecked Sendable {
        let entered: XCTestExpectation
        private let gate = DispatchSemaphore(value: 0)
        init(_ entered: XCTestExpectation) { self.entered = entered }
        func wait() {
            entered.fulfill()
            XCTAssertEqual(gate.wait(timeout: .now() + 5), .success, "Fixture release must be explicit")
        }
        func release() { gate.signal() }
    }

    @MainActor private func review(_ fixture: CoordinatorFixture) -> Review {
        Review(id: fixture.coordinator.session.id, raw: fixture.coordinator.session.rawTranscript,
               edited: fixture.coordinator.editedText, metricsID: fixture.coordinator.metrics?.session)
    }

    @MainActor private func assertReview(_ fixture: CoordinatorFixture, _ before: Review,
                                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(fixture.coordinator.session.phase, .review, file: file, line: line)
        XCTAssertEqual(fixture.coordinator.session.id, before.id, file: file, line: line)
        XCTAssertEqual(fixture.coordinator.session.rawTranscript, before.raw, file: file, line: line)
        XCTAssertEqual(fixture.coordinator.editedText, before.edited, file: file, line: line)
        XCTAssertEqual(fixture.coordinator.metrics?.session, before.metricsID, file: file, line: line)
        XCTAssertEqual(fixture.coordinator.microphone.state, .closed, file: file, line: line)
    }

    @MainActor func testFreshDecodeAndCopyAreUnsavedEvenBeforeEditingAndCancelKeepsResources() async throws {
        for text in ["Synthetic untouched decode", ""] {
            var confirmations = 0
            let fixture = try CoordinatorFixture(configureEnvironment: { environment in
                environment.confirmUnsavedReviewQuit = { _ in confirmations += 1; return .cancel }
            })
            fixture.inference.transcript = text
            await startRecording(fixture); await stopToReview(fixture)
            let before = review(fixture)
            XCTAssertTrue(fixture.coordinator.hasUnsavedReview)
            fixture.coordinator.copy()
            XCTAssertTrue(fixture.coordinator.hasUnsavedReview, "Copy is not a durable Save")
            fixture.coordinator.quit()
            assertReview(fixture, before)
            XCTAssertEqual(confirmations, 1)
            XCTAssertEqual(fixture.terminationCalls, 0)
            XCTAssertEqual(fixture.inference.counts.value.unloads, 0)
            XCTAssertFalse(fixture.coordinator.busy)
            XCTAssertTrue(fixture.coordinator.canSaveTranscript)
        }
    }

    @MainActor func testModalQuitReentryCannotDuplicateConfirmationOrEraseReview() async throws {
        var owner: AppCoordinator?, confirmations = 0, pickers = 0
        let fixture = try CoordinatorFixture(configureEnvironment: { environment in
            environment.confirmUnsavedReviewQuit = { _ in
                confirmations += 1
                owner?.quit(); owner?.discard(); owner?.start(); owner?.saveTranscript(); owner?.unload()
                return .cancel
            }
            environment.chooseTranscriptToSave = { _ in pickers += 1; return nil }
        })
        owner = fixture.coordinator
        await startRecording(fixture); await stopToReview(fixture)
        fixture.coordinator.editedText = "Keep this review"
        let before = review(fixture)
        fixture.coordinator.quit()
        assertReview(fixture, before)
        XCTAssertEqual(confirmations, 1)
        XCTAssertEqual(pickers, 0)
        XCTAssertEqual(fixture.inference.counts.value.unloads, 0)
        XCTAssertEqual(fixture.terminationCalls, 0)
        XCTAssertFalse(fixture.coordinator.busy)
    }

    @MainActor func testDiscardQuitDrainsExactlyOnceAfterDeliberateChoice() async throws {
        var confirmations = 0
        let fixture = try CoordinatorFixture(configureEnvironment: { environment in
            environment.confirmUnsavedReviewQuit = { _ in confirmations += 1; return .discard }
        })
        await startRecording(fixture); await stopToReview(fixture)
        let unload = ControlledDelivery(), entered = expectation(description: "final unload held")
        fixture.inference.unloadGate = unload; fixture.inference.onUnload = entered
        fixture.terminated = expectation(description: "discard terminated after drain")
        fixture.coordinator.quit(); fixture.coordinator.quit()
        await fulfillment(of: [entered], timeout: 2); await unload.waitUntilSuspended()
        XCTAssertEqual(confirmations, 1)
        XCTAssertEqual(fixture.terminationCalls, 0)
        await unload.release()
        await fulfillment(of: [try XCTUnwrap(fixture.terminated)], timeout: 2)
        XCTAssertEqual(fixture.inference.counts.value.unloads, 1)
        XCTAssertEqual(fixture.terminationCalls, 1)
        XCTAssertTrue(fixture.coordinator.terminationReady)
    }

    @MainActor func testQuitSaveWritesExactEditedTextBeforeTermination() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clavune-quit-save-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("review.txt")
        var confirmations = 0, pickers = 0
        let fixture = try CoordinatorFixture(configureEnvironment: { environment in
            environment.confirmUnsavedReviewQuit = { _ in confirmations += 1; return .save }
            environment.chooseTranscriptToSave = { _ in pickers += 1; return target }
            environment.writeTranscript = { try TranscriptFileStore.write($0, to: $1) }
        })
        await startRecording(fixture); await stopToReview(fixture)
        fixture.coordinator.editedText = "Synthetic edited Straße\nExact save snapshot."
        fixture.terminated = expectation(description: "save then terminate")
        fixture.coordinator.quit(); fixture.coordinator.quit()
        await fulfillment(of: [try XCTUnwrap(fixture.terminated)], timeout: 2)
        XCTAssertEqual(try Data(contentsOf: target), Data("Synthetic edited Straße\nExact save snapshot.".utf8))
        XCTAssertEqual(confirmations, 1); XCTAssertEqual(pickers, 1)
        XCTAssertEqual(fixture.terminationCalls, 1)
        XCTAssertTrue(fixture.clipboard.calls.isEmpty)
    }

    @MainActor func testQuitSavePickerCancelKeepsReviewDirtyAndDoesNotUnload() async throws {
        var pickers = 0
        let fixture = try CoordinatorFixture(configureEnvironment: { environment in
            environment.confirmUnsavedReviewQuit = { _ in .save }
            environment.chooseTranscriptToSave = { _ in pickers += 1; return nil }
        })
        await startRecording(fixture); await stopToReview(fixture)
        let before = review(fixture)
        fixture.coordinator.quit()
        assertReview(fixture, before)
        XCTAssertEqual(pickers, 1)
        XCTAssertEqual(fixture.terminationCalls, 0)
        XCTAssertEqual(fixture.inference.counts.value.unloads, 0)
        XCTAssertTrue(fixture.coordinator.hasUnsavedReview)
        XCTAssertFalse(fixture.coordinator.busy)
    }

    @MainActor func testQuitSaveFailureKeepsReviewDirtyAndDoesNotUnload() async throws {
        let selected = selected
        let fixture = try CoordinatorFixture(configureEnvironment: { environment in
            environment.confirmUnsavedReviewQuit = { _ in .save }
            environment.chooseTranscriptToSave = { _ in selected }
            environment.writeTranscript = { _, _ in throw TranscriptFileStore.Failure.invalidFile }
        })
        await startRecording(fixture); await stopToReview(fixture)
        let before = review(fixture)
        fixture.coordinator.quit(); await waitForOperation(fixture)
        assertReview(fixture, before)
        XCTAssertEqual(fixture.coordinator.message, "Speichern fehlgeschlagen. Die Vorschau bleibt erhalten.")
        XCTAssertTrue(fixture.coordinator.hasUnsavedReview)
        XCTAssertFalse(fixture.coordinator.busy)
        XCTAssertEqual(fixture.terminationCalls, 0)
        XCTAssertEqual(fixture.inference.counts.value.unloads, 0)
    }

    @MainActor func testNewerEditsDuringQuitSaveRemainUnsavedWithoutRepeatedQuitOrBlindRetry() async throws {
        let held = HeldWork(expectation(description: "quit writer held")), selected = selected
        defer { held.release() }
        let written = FixtureValue<[String]>([])
        var confirmations = 0, pickers = 0
        let fixture = try CoordinatorFixture(configureEnvironment: { environment in
            environment.confirmUnsavedReviewQuit = { _ in confirmations += 1; return .save }
            environment.chooseTranscriptToSave = { _ in pickers += 1; return selected }
            environment.writeTranscript = { text, _ in held.wait(); written.update { $0.append(text) } }
        })
        await startRecording(fixture); await stopToReview(fixture)
        fixture.coordinator.editedText = "written snapshot"
        fixture.coordinator.quit()
        await fulfillment(of: [held.entered], timeout: 2)
        fixture.coordinator.editedText = "newer unsaved edit"
        fixture.coordinator.quit(); fixture.coordinator.quit()
        held.release(); await waitForOperation(fixture)
        XCTAssertEqual(written.value, ["written snapshot"])
        XCTAssertEqual(fixture.coordinator.editedText, "newer unsaved edit")
        XCTAssertTrue(fixture.coordinator.hasUnsavedReview)
        XCTAssertEqual(confirmations, 1); XCTAssertEqual(pickers, 1)
        XCTAssertEqual(fixture.terminationCalls, 0)
        XCTAssertFalse(fixture.coordinator.busy)
        fixture.coordinator.editedText = "written snapshot"
        XCTAssertFalse(fixture.coordinator.hasUnsavedReview, "The savepoint is the actually written snapshot")
    }

    @MainActor func testCancelDuringQuitSaveNeverTreatsUnconfirmedWriteAsSaved() async throws {
        let held = HeldWork(expectation(description: "cancelled writer held")), selected = selected
        defer { held.release() }
        let written = FixtureValue("")
        let fixture = try CoordinatorFixture(configureEnvironment: { environment in
            environment.confirmUnsavedReviewQuit = { _ in .save }
            environment.chooseTranscriptToSave = { _ in selected }
            environment.writeTranscript = { text, _ in held.wait(); written.value = text }
        })
        await startRecording(fixture); await stopToReview(fixture)
        let before = review(fixture)
        fixture.coordinator.quit()
        await fulfillment(of: [held.entered], timeout: 2)
        fixture.coordinator.cancel()
        assertReview(fixture, before)
        held.release(); await waitForOperation(fixture)
        XCTAssertEqual(written.value, before.edited, "A worker may have completed after cancellation")
        assertReview(fixture, before)
        XCTAssertTrue(fixture.coordinator.hasUnsavedReview, "Unconfirmed completion is never a savepoint")
        XCTAssertFalse(fixture.coordinator.busy)
        XCTAssertEqual(fixture.terminationCalls, 0)
    }

    @MainActor func testSaveRelaunchOpenRetainsExactTextAndCleanReviewWithoutQuitAlert() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clavune-reopen-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("review.txt")
        var confirmations = 0
        let configure: @MainActor (inout CoordinatorEnvironment) -> Void = { environment in
            environment.chooseTranscriptToSave = { _ in target }
            environment.chooseTranscriptToOpen = { _ in target }
            environment.writeTranscript = { try TranscriptFileStore.write($0, to: $1) }
            environment.readTranscript = { try TranscriptFileStore.read($0) }
            environment.confirmUnsavedReviewQuit = { _ in confirmations += 1; return .cancel }
        }
        let original = try CoordinatorFixture(configureEnvironment: configure)
        await startRecording(original); await stopToReview(original)
        original.coordinator.editedText = "Saved review with Grüße\nSecond line."
        original.coordinator.saveTranscript(); await waitForOperation(original)
        XCTAssertFalse(original.coordinator.hasUnsavedReview)
        original.terminated = expectation(description: "clean saved review quit")
        original.coordinator.quit()
        await fulfillment(of: [try XCTUnwrap(original.terminated)], timeout: 2)
        let reopened = try CoordinatorFixture(modelSelectionEnabled: false, configureEnvironment: configure)
        reopened.coordinator.openTranscript(); await waitForOperation(reopened)
        XCTAssertEqual(reopened.coordinator.editedText, "Saved review with Grüße\nSecond line.")
        XCTAssertEqual(reopened.coordinator.session.rawTranscript, reopened.coordinator.editedText)
        XCTAssertFalse(reopened.coordinator.hasUnsavedReview)
        XCTAssertEqual(reopened.inference.counts.value.loads, 0)
        XCTAssertEqual(reopened.resources.counts.value.opened, 0)
        reopened.terminated = expectation(description: "clean opened review quit")
        reopened.coordinator.quit()
        await fulfillment(of: [try XCTUnwrap(reopened.terminated)], timeout: 2)
        XCTAssertEqual(confirmations, 0)
        XCTAssertTrue(original.clipboard.calls.isEmpty); XCTAssertTrue(reopened.clipboard.calls.isEmpty)
    }

    @MainActor func testQuitCancelDuringAdmittedReadLeavesReviewAndReadTaskUntouched() async throws {
        let held = HeldWork(expectation(description: "read pending at Quit")), selected = selected
        defer { held.release() }
        let cancelled = FixtureValue(true)
        let fixture = try CoordinatorFixture(configureEnvironment: { environment in
            environment.chooseTranscriptToOpen = { _ in selected }
            environment.readTranscript = { _ in
                held.wait(); cancelled.value = Task.isCancelled; throw TranscriptFileStore.Failure.invalidFile
            }
            environment.confirmUnsavedReviewQuit = { _ in .cancel }
        })
        await startRecording(fixture); await stopToReview(fixture)
        let before = review(fixture)
        fixture.coordinator.openTranscript()
        await fulfillment(of: [held.entered], timeout: 2)
        fixture.coordinator.quit()
        assertReview(fixture, before)
        XCTAssertTrue(fixture.coordinator.operationPending)
        XCTAssertEqual(fixture.terminationCalls, 0)
        held.release(); await waitForOperation(fixture)
        XCTAssertFalse(cancelled.value, "Cancel in the Quit alert leaves admitted work intact")
        assertReview(fixture, before)
        XCTAssertEqual(fixture.terminationCalls, 0)
    }

    @MainActor func testQuitSaveWaitsForReadDrainAndRejectsItsLateReplacement() async throws {
        let held = HeldWork(expectation(description: "read held before quit-save")), selected = selected
        defer { held.release() }
        var savePickers = 0, replacementAlerts = 0
        let written = FixtureValue<[String]>([]), cancelled = FixtureValue(false)
        let fixture = try CoordinatorFixture(configureEnvironment: { environment in
            environment.chooseTranscriptToOpen = { _ in selected }
            environment.readTranscript = { _ in held.wait(); cancelled.value = Task.isCancelled; return "late replacement" }
            environment.confirmTranscriptReplacement = { _ in replacementAlerts += 1; return true }
            environment.confirmUnsavedReviewQuit = { _ in .save }
            environment.chooseTranscriptToSave = { _ in savePickers += 1; return selected }
            environment.writeTranscript = { text, _ in written.update { $0.append(text) } }
        })
        await startRecording(fixture); await stopToReview(fixture)
        fixture.coordinator.editedText = "review chosen for quit-save"
        let before = review(fixture)
        fixture.coordinator.openTranscript()
        await fulfillment(of: [held.entered], timeout: 2)
        fixture.terminated = expectation(description: "read drain then save then quit")
        fixture.coordinator.quit(); fixture.coordinator.quit()
        assertReview(fixture, before)
        XCTAssertEqual(savePickers, 0); XCTAssertEqual(fixture.terminationCalls, 0)
        held.release()
        await fulfillment(of: [try XCTUnwrap(fixture.terminated)], timeout: 2)
        XCTAssertTrue(cancelled.value)
        XCTAssertEqual(replacementAlerts, 0)
        XCTAssertEqual(savePickers, 1)
        XCTAssertEqual(written.value, [before.edited])
    }

    @MainActor func testQuitSaveDuringOpenPickerWaitsForModalAndRejectsLateOpen() async throws {
        let selected = selected
        var owner: AppCoordinator?, openPickers = 0, savePickers = 0, confirmations = 0
        let reads = FixtureValue<[URL]>([]), writes = FixtureValue<[String]>([])
        let fixture = try CoordinatorFixture(configureEnvironment: { environment in
            environment.chooseTranscriptToOpen = { _ in
                openPickers += 1
                if openPickers == 1 {
                    owner?.quit()
                    owner?.quit()
                }
                return selected
            }
            environment.readTranscript = { url in
                reads.update { $0.append(url) }
                return "late open must not replace the review"
            }
            environment.confirmUnsavedReviewQuit = { _ in confirmations += 1; return .save }
            environment.chooseTranscriptToSave = { _ in savePickers += 1; return selected }
            environment.writeTranscript = { text, _ in writes.update { $0.append(text) } }
        })
        owner = fixture.coordinator
        await startRecording(fixture); await stopToReview(fixture)
        fixture.coordinator.editedText = "the exact draft chosen for Quit → Save"
        let before = review(fixture)
        fixture.terminated = expectation(description: "modal Open unwinds, then saved Quit terminates")

        fixture.coordinator.openTranscript()

        await fulfillment(of: [try XCTUnwrap(fixture.terminated)], timeout: 2)
        assertReview(fixture, before)
        XCTAssertEqual(openPickers, 1)
        XCTAssertEqual(savePickers, 1)
        XCTAssertEqual(confirmations, 1, "reentrant Quit must not open another confirmation")
        XCTAssertTrue(reads.value.isEmpty, "the cancelled Open selection must never reach the reader")
        XCTAssertEqual(writes.value, [before.edited])
        XCTAssertFalse(fixture.coordinator.hasUnsavedReview)
        XCTAssertEqual(fixture.terminationCalls, 1)
    }

    @MainActor func testModalOpenQuitSavePickerCancelAndWriteFailureKeepReview() async throws {
        for failWrite in [false, true] {
            var owner: AppCoordinator?, openPickers = 0, savePickers = 0
            let selected = selected
            let fixture = try CoordinatorFixture(configureEnvironment: { environment in
                environment.chooseTranscriptToOpen = { _ in
                    openPickers += 1
                    if openPickers == 1 { owner?.quit() }
                    return selected
                }
                environment.readTranscript = { _ in "late replacement" }
                environment.confirmUnsavedReviewQuit = { _ in .save }
                environment.chooseTranscriptToSave = { _ in
                    savePickers += 1
                    return failWrite ? selected : nil
                }
                environment.writeTranscript = { _, _ in
                    if failWrite { throw TranscriptFileStore.Failure.invalidFile }
                }
            })
            owner = fixture.coordinator
            await startRecording(fixture); await stopToReview(fixture)
            fixture.coordinator.editedText = failWrite ? "draft survives write failure" : "draft survives picker cancel"
            let before = review(fixture)

            fixture.coordinator.openTranscript()
            if failWrite { await waitForOperation(fixture) }

            assertReview(fixture, before)
            XCTAssertEqual(openPickers, 1)
            XCTAssertEqual(savePickers, 1)
            XCTAssertTrue(fixture.coordinator.hasUnsavedReview)
            XCTAssertEqual(fixture.terminationCalls, 0)
            XCTAssertFalse(fixture.coordinator.busy)
        }
    }

    @MainActor func testModalOpenQuitSaveRejectsNewerReviewSnapshot() async throws {
        var owner: AppCoordinator?, savePickers = 0
        let selected = selected
        let reads = FixtureValue(0)
        let fixture = try CoordinatorFixture(configureEnvironment: { environment in
            environment.chooseTranscriptToOpen = { _ in
                owner?.quit()
                owner?.editedText = "new edit after the Quit snapshot"
                return selected
            }
            environment.readTranscript = { _ in reads.update { $0 += 1 }; return "late replacement" }
            environment.confirmUnsavedReviewQuit = { _ in .save }
            environment.chooseTranscriptToSave = { _ in savePickers += 1; return selected }
        })
        owner = fixture.coordinator
        await startRecording(fixture); await stopToReview(fixture)
        fixture.coordinator.editedText = "draft captured by Quit"
        let reviewID = fixture.coordinator.session.id

        fixture.coordinator.openTranscript()

        XCTAssertEqual(fixture.coordinator.session.phase, .review)
        XCTAssertEqual(fixture.coordinator.session.id, reviewID)
        XCTAssertEqual(fixture.coordinator.editedText, "new edit after the Quit snapshot")
        XCTAssertTrue(fixture.coordinator.hasUnsavedReview)
        XCTAssertEqual(savePickers, 0, "changed text must not be saved under the older Quit decision")
        XCTAssertEqual(reads.value, 0, "the late Open selection must not replace either edit")
        XCTAssertEqual(fixture.terminationCalls, 0)
        XCTAssertFalse(fixture.coordinator.busy)
    }

    @MainActor func testDeferredQuitSaveRejectsTextChangedInItsSavePicker() async throws {
        var owner: AppCoordinator?, savePickers = 0
        let writes = FixtureValue(0)
        let selected = selected
        let fixture = try CoordinatorFixture(configureEnvironment: { environment in
            environment.chooseTranscriptToOpen = { _ in
                owner?.quit()
                return selected
            }
            environment.readTranscript = { _ in "late replacement" }
            environment.confirmUnsavedReviewQuit = { _ in .save }
            environment.chooseTranscriptToSave = { _ in
                savePickers += 1
                owner?.editedText = "newer edit while deferred Save picker is open"
                return selected
            }
            environment.writeTranscript = { _, _ in writes.update { $0 += 1 } }
        })
        owner = fixture.coordinator
        await startRecording(fixture); await stopToReview(fixture)
        fixture.coordinator.editedText = "draft captured by Quit"
        let reviewID = fixture.coordinator.session.id

        fixture.coordinator.openTranscript()

        XCTAssertEqual(fixture.coordinator.session.phase, .review)
        XCTAssertEqual(fixture.coordinator.session.id, reviewID)
        XCTAssertEqual(fixture.coordinator.editedText, "newer edit while deferred Save picker is open")
        XCTAssertTrue(fixture.coordinator.hasUnsavedReview)
        XCTAssertEqual(savePickers, 1)
        XCTAssertEqual(writes.value, 0, "the stale Quit snapshot must not be written")
        XCTAssertEqual(fixture.terminationCalls, 0)
        XCTAssertFalse(fixture.coordinator.busy)
    }

    @MainActor func testQuitSaveRejectsCanonicalEquivalentButByteDifferentPickerEdit() async throws {
        var owner: AppCoordinator?, savePickers = 0
        let selected = selected, writes = FixtureValue(0)
        let decomposed = "e\u{0301}", composed = "\u{00E9}"
        let fixture = try CoordinatorFixture(configureEnvironment: { environment in
            environment.confirmUnsavedReviewQuit = { _ in .save }
            environment.chooseTranscriptToSave = { _ in
                savePickers += 1
                owner?.editedText = composed
                return selected
            }
            environment.writeTranscript = { _, _ in writes.update { $0 += 1 } }
        })
        owner = fixture.coordinator
        await startRecording(fixture); await stopToReview(fixture)
        fixture.coordinator.editedText = decomposed
        let reviewID = fixture.coordinator.session.id

        fixture.coordinator.quit()

        XCTAssertEqual(savePickers, 1)
        XCTAssertEqual(writes.value, 0, "Canonical String equality must not authorize different UTF-8 bytes")
        XCTAssertEqual(fixture.coordinator.session.id, reviewID)
        XCTAssertEqual(Data(fixture.coordinator.editedText.utf8), Data(composed.utf8))
        XCTAssertTrue(fixture.coordinator.hasUnsavedReview)
        XCTAssertEqual(fixture.terminationCalls, 0)
        XCTAssertFalse(fixture.coordinator.busy)
    }

    @MainActor func testQuitSaveDuringExplicitSavePickerWaitsForAdmissionRelease() async throws {
        var owner: AppCoordinator?, savePickers = 0
        let selected = selected, writes = FixtureValue<[String]>([])
        let fixture = try CoordinatorFixture(configureEnvironment: { environment in
            environment.confirmUnsavedReviewQuit = { _ in .save }
            environment.chooseTranscriptToSave = { _ in
                savePickers += 1
                if savePickers == 1 { owner?.quit(); owner?.quit(); return nil }
                return selected
            }
            environment.writeTranscript = { text, _ in writes.update { $0.append(text) } }
        })
        owner = fixture.coordinator
        await startRecording(fixture); await stopToReview(fixture)
        fixture.coordinator.editedText = "draft retained from the explicit Save picker"
        let before = review(fixture)
        fixture.terminated = expectation(description: "explicit Save modal unwinds before Quit Save")

        fixture.coordinator.saveTranscript()

        await fulfillment(of: [try XCTUnwrap(fixture.terminated)], timeout: 2)
        assertReview(fixture, before)
        XCTAssertEqual(savePickers, 2, "the quit-owned Save picker opens after the original panel unwinds")
        XCTAssertEqual(writes.value, [before.edited])
        XCTAssertFalse(fixture.coordinator.hasUnsavedReview)
        XCTAssertEqual(fixture.terminationCalls, 1)
    }

    @MainActor func testQuitSaveDuringModelPickerWaitsForModalAdmissionRelease() async throws {
        var owner: AppCoordinator?, savePickers = 0
        let selected = selected, writes = FixtureValue<[String]>([]), modelImports = FixtureValue(0)
        let fixture = try CoordinatorFixture(configureEnvironment: { environment in
            environment.confirmUnsavedReviewQuit = { _ in .save }
            environment.chooseTranscriptToSave = { _ in savePickers += 1; return selected }
            environment.writeTranscript = { text, _ in writes.update { $0.append(text) } }
            environment.importManagedModel = { _ in
                modelImports.update { $0 += 1 }
                throw DictationError.modelInvalid
            }
        })
        owner = fixture.coordinator
        await startRecording(fixture); await stopToReview(fixture)
        fixture.coordinator.editedText = "draft preserved across model-picker Quit"
        let before = review(fixture)
        fixture.chooseModel = { owner?.quit(); return selected }
        fixture.terminated = expectation(description: "model picker unwinds, then saved Quit terminates")

        fixture.coordinator.importModel()

        await fulfillment(of: [try XCTUnwrap(fixture.terminated)], timeout: 2)
        assertReview(fixture, before)
        XCTAssertEqual(savePickers, 1)
        XCTAssertEqual(writes.value, [before.edited])
        XCTAssertEqual(modelImports.value, 0, "a late model-picker return must not start model import")
        XCTAssertFalse(fixture.coordinator.hasUnsavedReview)
        XCTAssertEqual(fixture.terminationCalls, 1)
    }

    @MainActor func testCancelQuitWhileOpenPickerWaitsForDeferredSaveKeepsReview() async throws {
        var owner: AppCoordinator?, confirmations = 0, savePickers = 0
        let selected = selected
        let reads = FixtureValue(0), writes = FixtureValue(0)
        let fixture = try CoordinatorFixture(configureEnvironment: { environment in
            environment.chooseTranscriptToOpen = { _ in
                owner?.quit()
                owner?.cancel()
                return selected
            }
            environment.confirmUnsavedReviewQuit = { _ in confirmations += 1; return .save }
            environment.chooseTranscriptToSave = { _ in savePickers += 1; return selected }
            environment.readTranscript = { _ in reads.update { $0 += 1 }; return "late replacement" }
            environment.writeTranscript = { _, _ in writes.update { $0 += 1 } }
        })
        owner = fixture.coordinator
        await startRecording(fixture); await stopToReview(fixture)
        fixture.coordinator.editedText = "Keep this review when Quit is cancelled in the picker"
        let before = review(fixture)

        fixture.coordinator.openTranscript()

        assertReview(fixture, before)
        XCTAssertTrue(fixture.coordinator.hasUnsavedReview)
        XCTAssertEqual(confirmations, 1)
        XCTAssertEqual(savePickers, 0, "Cancel clears the deferred Quit Save before the picker unwinds")
        XCTAssertEqual(reads.value, 0, "the late Open selection is invalidated")
        XCTAssertEqual(writes.value, 0)
        XCTAssertEqual(fixture.terminationCalls, 0)
        XCTAssertFalse(fixture.coordinator.busy)
    }

    @MainActor func testCancelQuitInsideModelPickerRejectsLateModelURLAndAllowsFreshQuit() async throws {
        var owner: AppCoordinator?, confirmations = 0, savePickers = 0
        let selected = selected, modelImports = FixtureValue(0), writes = FixtureValue<[String]>([])
        let fixture = try CoordinatorFixture(configureEnvironment: { environment in
            environment.confirmUnsavedReviewQuit = { _ in confirmations += 1; return .save }
            environment.chooseTranscriptToSave = { _ in savePickers += 1; return selected }
            environment.writeTranscript = { text, _ in writes.update { $0.append(text) } }
            environment.importManagedModel = { _ in
                modelImports.update { $0 += 1 }
                throw DictationError.modelInvalid
            }
        })
        owner = fixture.coordinator
        await startRecording(fixture); await stopToReview(fixture)
        fixture.coordinator.editedText = "same review after cancelled model-picker Quit"
        let before = review(fixture)
        fixture.chooseModel = {
            owner?.quit()
            owner?.cancel()
            return selected
        }

        fixture.coordinator.importModel()

        assertReview(fixture, before)
        XCTAssertTrue(fixture.coordinator.hasUnsavedReview)
        XCTAssertEqual(confirmations, 1)
        XCTAssertEqual(savePickers, 0, "Cancel clears the deferred Quit Save")
        XCTAssertEqual(modelImports.value, 0, "The invalidated model URL cannot start import")
        XCTAssertTrue(writes.value.isEmpty)
        XCTAssertEqual(fixture.terminationCalls, 0)
        XCTAssertFalse(fixture.coordinator.busy)

        fixture.terminated = expectation(description: "fresh Quit saves the retained review")
        fixture.coordinator.quit()
        await fulfillment(of: [try XCTUnwrap(fixture.terminated)], timeout: 2)
        assertReview(fixture, before)
        XCTAssertEqual(confirmations, 2)
        XCTAssertEqual(savePickers, 1)
        XCTAssertEqual(modelImports.value, 0)
        XCTAssertEqual(writes.value, [before.edited])
        XCTAssertFalse(fixture.coordinator.hasUnsavedReview)
        XCTAssertEqual(fixture.terminationCalls, 1)
    }

    @MainActor func testCancelWhileQuitWaitsForReadDrainCancelsOnlyTheQuitIntent() async throws {
        let held = HeldWork(expectation(description: "read held before quit cancellation")), selected = selected
        defer { held.release() }
        var savePickers = 0
        let fixture = try CoordinatorFixture(configureEnvironment: { environment in
            environment.chooseTranscriptToOpen = { _ in selected }
            environment.readTranscript = { _ in held.wait(); return "must not replace" }
            environment.confirmUnsavedReviewQuit = { _ in .save }
            environment.chooseTranscriptToSave = { _ in savePickers += 1; return selected }
        })
        await startRecording(fixture); await stopToReview(fixture)
        let before = review(fixture)
        fixture.coordinator.openTranscript()
        await fulfillment(of: [held.entered], timeout: 2)
        fixture.coordinator.quit(); fixture.coordinator.cancel()
        held.release(); await waitForOperation(fixture)
        // The exact pending task has drained; the retained Quit continuation has
        // no valid attempt token, so it cannot open a picker or close the app.
        assertReview(fixture, before)
        XCTAssertEqual(savePickers, 0)
        XCTAssertEqual(fixture.terminationCalls, 0)
        XCTAssertFalse(fixture.coordinator.busy)
    }

    @MainActor func testModelImportCancelPreservesReviewAndRejectsLateSelection() async throws {
        let held = HeldWork(expectation(description: "model import held")), selected = selected
        defer { held.release() }
        let candidate = try XCTUnwrap(ModelStore.candidates().first)
        let late = ModelStore.Installed(url: URL(fileURLWithPath: "/synthetic-late-model-never-opened"), candidate: candidate)
        let fixture = try CoordinatorFixture(configureEnvironment: { environment in
            environment.importManagedModel = { _ in held.wait(); return late }
        })
        await startRecording(fixture); await stopToReview(fixture)
        fixture.coordinator.editedText = "Keep edited review while choosing models"
        let before = review(fixture), status = fixture.coordinator.modelStatus
        fixture.chooseModel = { selected }; fixture.coordinator.importModel()
        await fulfillment(of: [held.entered], timeout: 2)
        fixture.coordinator.cancel()
        assertReview(fixture, before)
        XCTAssertTrue(fixture.coordinator.operationPending)
        XCTAssertFalse(fixture.coordinator.closePending)
        held.release(); await waitForOperation(fixture)
        assertReview(fixture, before)
        XCTAssertNotEqual(fixture.coordinator.modelStatus, status)
        XCTAssertEqual(fixture.inference.counts.value.unloads, 0, "Rejected late selection cannot evict the old model")
        XCTAssertTrue(fixture.coordinator.hasUnsavedReview)
        XCTAssertFalse(fixture.coordinator.busy)
    }

    @MainActor func testModelPickerCancelPreservesReviewWithoutAdmittingWorker() async throws {
        var owner: AppCoordinator?
        let selected = selected
        let fixture = try CoordinatorFixture()
        owner = fixture.coordinator
        await startRecording(fixture); await stopToReview(fixture)
        let before = review(fixture)
        fixture.chooseModel = { owner?.cancel(); return selected }
        fixture.coordinator.importModel()
        assertReview(fixture, before)
        XCTAssertFalse(fixture.coordinator.operationPending)
        XCTAssertFalse(fixture.coordinator.busy)
        XCTAssertEqual(fixture.inference.counts.value.unloads, 0)
    }

    @MainActor func testModelUnloadCancelPreservesReviewUntilRealDrain() async throws {
        let fixture = try CoordinatorFixture()
        await startRecording(fixture); await stopToReview(fixture)
        fixture.coordinator.editedText = "Unrelated unload cannot erase this edit"
        let before = review(fixture)
        let unload = ControlledDelivery(), entered = expectation(description: "unload held for cancel")
        fixture.inference.unloadGate = unload; fixture.inference.onUnload = entered
        fixture.coordinator.unload()
        await fulfillment(of: [entered], timeout: 2); await unload.waitUntilSuspended()
        fixture.coordinator.cancel()
        assertReview(fixture, before)
        XCTAssertTrue(fixture.coordinator.busy)
        XCTAssertFalse(fixture.coordinator.closePending)
        await unload.release(); await waitForOperation(fixture)
        assertReview(fixture, before)
        XCTAssertFalse(fixture.coordinator.busy)
        XCTAssertEqual(fixture.resources.counts.value.closed, 1)
        XCTAssertTrue(fixture.clipboard.calls.isEmpty)
    }

    @MainActor func testQuitCancelDuringModelUnloadDoesNotCancelResourcesOrReview() async throws {
        var confirmations = 0
        let fixture = try CoordinatorFixture(configureEnvironment: { environment in
            environment.confirmUnsavedReviewQuit = { _ in confirmations += 1; return .cancel }
        })
        await startRecording(fixture); await stopToReview(fixture)
        let before = review(fixture), cancelled = FixtureValue(true)
        let unload = ControlledDelivery(), entered = expectation(description: "unload held during Quit choice")
        fixture.inference.unloadGate = unload; fixture.inference.onUnload = entered
        fixture.inference.onUnloadCompleted = { cancelled.value = Task.isCancelled }
        fixture.coordinator.unload()
        await fulfillment(of: [entered], timeout: 2); await unload.waitUntilSuspended()
        fixture.coordinator.quit()
        assertReview(fixture, before)
        XCTAssertEqual(confirmations, 1)
        XCTAssertTrue(fixture.coordinator.operationPending)
        await unload.release(); await waitForOperation(fixture)
        XCTAssertFalse(cancelled.value)
        assertReview(fixture, before)
        XCTAssertEqual(fixture.terminationCalls, 0)
        XCTAssertEqual(fixture.inference.counts.value.unloads, 1)
    }

    @MainActor func testQuitSaveDuringModelUnloadWaitsForDrainThenSavesSameReview() async throws {
        let selected = selected, written = FixtureValue<[String]>([])
        var confirmations = 0, pickers = 0
        let fixture = try CoordinatorFixture(configureEnvironment: { environment in
            environment.confirmUnsavedReviewQuit = { _ in confirmations += 1; return .save }
            environment.chooseTranscriptToSave = { _ in pickers += 1; return selected }
            environment.writeTranscript = { text, _ in written.update { $0.append(text) } }
        })
        await startRecording(fixture); await stopToReview(fixture)
        let before = review(fixture)
        let unload = ControlledDelivery(), entered = expectation(description: "unload held before Quit Save")
        fixture.inference.unloadGate = unload; fixture.inference.onUnload = entered
        fixture.coordinator.unload()
        await fulfillment(of: [entered], timeout: 2); await unload.waitUntilSuspended()
        fixture.terminated = expectation(description: "model drain then save then terminate")
        fixture.coordinator.quit(); fixture.coordinator.quit()
        assertReview(fixture, before)
        XCTAssertEqual(pickers, 0); XCTAssertEqual(fixture.terminationCalls, 0)
        fixture.inference.unloadGate = nil; fixture.inference.onUnload = nil
        await unload.release()
        await fulfillment(of: [try XCTUnwrap(fixture.terminated)], timeout: 2)
        XCTAssertEqual(confirmations, 1); XCTAssertEqual(pickers, 1)
        XCTAssertEqual(written.value, [before.edited])
        XCTAssertEqual(fixture.inference.counts.value.unloads, 2)
    }

    @MainActor private func editableReview(in view: NSView) -> PlainTranscriptTextView? {
        if let editor = view as? PlainTranscriptTextView, editor.isEditable { return editor }
        for child in view.subviews {
            if let editor = editableReview(in: child) { return editor }
        }
        return nil
    }

    @MainActor private func refresh(_ host: NSView) async {
        host.layoutSubtreeIfNeeded()
        let updated = expectation(description: "offscreen review host update")
        DispatchQueue.main.async { updated.fulfill() }
        await fulfillment(of: [updated], timeout: 2)
        host.layoutSubtreeIfNeeded()
    }

    @MainActor func testQuitAndModelCancelPreserveNativeEditorIdentityUndoAndRedo() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CLAVUNE_RUN_UI_HOST_FIXTURES"] == "1",
                          "Run only in the authorized macOS in-memory UI-host fixture pass")
        _ = NSApplication.shared
        // Independent reviews give both interruption routes their own real edit;
        // neither can pass by reusing already-undone state from the other route.
        for cancelModel in [false, true] {
            var confirmations = 0
            let selected = selected
            let fixture = try CoordinatorFixture(configureEnvironment: { environment in
                environment.chooseTranscriptToOpen = { _ in selected }
                environment.readTranscript = { _ in "opened review" }
                environment.confirmUnsavedReviewQuit = { _ in confirmations += 1; return .cancel }
            })
            fixture.coordinator.openTranscript(); await waitForOperation(fixture)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 900),
                                  styleMask: [.titled], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let host = NSHostingView(rootView: DictationView(coordinator: fixture.coordinator))
            window.contentView = host
            await refresh(host)
            let editor = try XCTUnwrap(editableReview(in: host))
            XCTAssertTrue(window.makeFirstResponder(editor))
            let undo = try XCTUnwrap(editor.undoManager)
            undo.beginUndoGrouping()
            editor.insertText(" edited", replacementRange: NSRange(location: (editor.string as NSString).length, length: 0))
            undo.endUndoGrouping()
            XCTAssertEqual(fixture.coordinator.editedText, "opened review edited")
            XCTAssertTrue(fixture.coordinator.hasUnsavedReview)
            XCTAssertTrue(undo.canUndo, "Fixture must establish native Undo before the interruption")
            let before = review(fixture)
            if cancelModel {
                let unload = ControlledDelivery(), entered = expectation(description: "offscreen model unload held")
                fixture.inference.unloadGate = unload; fixture.inference.onUnload = entered
                fixture.coordinator.unload()
                await fulfillment(of: [entered], timeout: 2); await unload.waitUntilSuspended()
                fixture.coordinator.cancel()
                await refresh(host)
                assertReview(fixture, before)
                XCTAssertTrue(try XCTUnwrap(editableReview(in: host)) === editor)
                XCTAssertTrue(editor.undoManager === undo)
                XCTAssertTrue(undo.canUndo)
                await unload.release(); await waitForOperation(fixture)
            } else { fixture.coordinator.quit() }
            await refresh(host)
            assertReview(fixture, before)
            XCTAssertTrue(try XCTUnwrap(editableReview(in: host)) === editor)
            XCTAssertTrue(editor.undoManager === undo)
            XCTAssertTrue(undo.canUndo)
            undo.undo()
            XCTAssertEqual(editor.string, "opened review")
            XCTAssertEqual(fixture.coordinator.editedText, "opened review")
            XCTAssertFalse(fixture.coordinator.hasUnsavedReview, "Undo to the opened savepoint is clean")
            XCTAssertTrue(undo.canRedo)
            undo.redo()
            XCTAssertEqual(editor.string, "opened review edited")
            XCTAssertEqual(fixture.coordinator.editedText, "opened review edited")
            XCTAssertTrue(fixture.coordinator.hasUnsavedReview)
            XCTAssertEqual(confirmations, cancelModel ? 0 : 1)
            XCTAssertEqual(fixture.terminationCalls, 0)
            XCTAssertFalse(window.isVisible)
            XCTAssertTrue(fixture.clipboard.calls.isEmpty)
        }
    }

}
