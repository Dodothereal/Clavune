import Foundation
import XCTest
@testable import ClavuneApp
@testable import ClavuneCore

/// Resource boundaries are injected; no panel, user file, clipboard, or real model opens.
final class TranscriptFileCoordinatorTests: UIFixtureAssertions {
    private let selected = URL(fileURLWithPath: "/synthetic-selected-transcript-never-opened.txt")

    private final class HeldRead: @unchecked Sendable {
        let entered: XCTestExpectation
        private let release = DispatchSemaphore(value: 0)
        init(_ entered: XCTestExpectation) { self.entered = entered }
        func read() -> String { entered.fulfill(); release.wait(); return "late opened text" }
        func resume() { release.signal() }
    }

    @MainActor func testOpenNeedsNoModelAndDoesNotStartResourcesOrClipboard() async throws {
        var openCalls = 0
        let selected = selected
        let fixture = try CoordinatorFixture(modelSelectionEnabled: false, configureEnvironment: { environment in
            environment.chooseTranscriptToOpen = { _ in openCalls += 1; return selected }
            environment.readTranscript = { _ in "synthetic file 👋🏽\nsecond line" }
        })
        XCTAssertEqual(openCalls, 0)
        XCTAssertFalse(fixture.coordinator.canSaveTranscript)
        XCTAssertTrue(fixture.coordinator.canOpenTranscript)
        fixture.coordinator.openTranscript()
        await waitForOperation(fixture)
        XCTAssertEqual(openCalls, 1)
        XCTAssertEqual(fixture.coordinator.session.phase, .review)
        XCTAssertEqual(fixture.coordinator.session.rawTranscript, "synthetic file 👋🏽\nsecond line")
        XCTAssertEqual(fixture.coordinator.editedText, fixture.coordinator.session.rawTranscript)
        XCTAssertNil(fixture.coordinator.metrics)
        XCTAssertFalse(fixture.coordinator.canStart)
        XCTAssertTrue(fixture.coordinator.canSaveTranscript)
        XCTAssertEqual(fixture.permissionCalls, 0)
        XCTAssertEqual(fixture.cancellationAllocationCalls, 0)
        XCTAssertEqual(fixture.resources.counts.value.opened, 0)
        XCTAssertEqual(fixture.inference.counts.value.loads, 0)
        XCTAssertEqual(fixture.inference.counts.value.decodes, 0)
        XCTAssertTrue(fixture.watchdog.handles.isEmpty)
        XCTAssertTrue(fixture.clipboard.calls.isEmpty)
    }

    @MainActor func testPanelCancellationAndReadFailurePreserveRawEditedIdentityAndMetrics() async throws {
        var selectedURL: URL?, reads = 0, confirmations = 0
        let readCalls = FixtureValue(0)
        let fixture = try CoordinatorFixture(configureEnvironment: { environment in
            environment.chooseTranscriptToOpen = { _ in selectedURL }
            environment.chooseTranscriptToSave = { _ in nil }
            environment.confirmTranscriptReplacement = { _ in confirmations += 1; return true }
            environment.readTranscript = { _ in
                readCalls.update { $0 += 1 }; throw TranscriptFileStore.Failure.invalidUTF8
            }
        })
        await startRecording(fixture); await stopToReview(fixture)
        let id = fixture.coordinator.session.id, raw = fixture.coordinator.session.rawTranscript
        let metricID = fixture.coordinator.metrics?.session
        fixture.coordinator.editedText = "unsaved edited text"
        let message = fixture.coordinator.message
        fixture.coordinator.openTranscript(); fixture.coordinator.saveTranscript()
        XCTAssertFalse(fixture.coordinator.busy)
        XCTAssertEqual(fixture.coordinator.message, message)
        XCTAssertEqual(readCalls.value, reads)
        selectedURL = selected
        fixture.coordinator.openTranscript(); await waitForOperation(fixture)
        reads += 1
        XCTAssertEqual(readCalls.value, reads)
        XCTAssertEqual(confirmations, 0, "A failed read never asks to discard the review")
        XCTAssertEqual(fixture.coordinator.session.id, id)
        XCTAssertEqual(fixture.coordinator.session.rawTranscript, raw)
        XCTAssertEqual(fixture.coordinator.editedText, "unsaved edited text")
        XCTAssertEqual(fixture.coordinator.metrics?.session, metricID)
        XCTAssertEqual(fixture.coordinator.message,
                       "Öffnen fehlgeschlagen. UTF-8-Klartext bis 4 MiB wählen. Die Vorschau bleibt erhalten.")
    }

    @MainActor func testFailedOpenAfterCancelledSessionRetainsAccurateErrorMessage() async throws {
        let selected = selected
        let fixture = try CoordinatorFixture(configureEnvironment: { environment in
            environment.chooseTranscriptToOpen = { _ in selected }
            environment.readTranscript = { _ in throw TranscriptFileStore.Failure.invalidUTF8 }
        })
        await startRecording(fixture); await cancelAndDrain(fixture)
        XCTAssertEqual(fixture.coordinator.session.phase, .cancelled)
        fixture.coordinator.openTranscript(); await waitForOperation(fixture)
        XCTAssertEqual(fixture.coordinator.session.phase, .cancelled)
        XCTAssertEqual(fixture.coordinator.message,
                       "Öffnen fehlgeschlagen. UTF-8-Klartext bis 4 MiB wählen. Die Vorschau bleibt erhalten.")
        XCTAssertFalse(fixture.coordinator.busy)
    }

    @MainActor func testReplacementRequiresConfirmationEvenForEmptyReviewAndAssignsNewIdentity() async throws {
        var confirm = false, confirmations = 0
        let selected = selected
        let fixture = try CoordinatorFixture(configureEnvironment: { environment in
            environment.chooseTranscriptToOpen = { _ in selected }
            environment.readTranscript = { _ in "" }
            environment.confirmTranscriptReplacement = { _ in confirmations += 1; return confirm }
        })
        await startRecording(fixture); await stopToReview(fixture)
        fixture.coordinator.editedText = ""
        let id = fixture.coordinator.session.id, raw = fixture.coordinator.session.rawTranscript
        fixture.coordinator.openTranscript(); await waitForOperation(fixture)
        XCTAssertEqual(confirmations, 1)
        XCTAssertEqual(fixture.coordinator.session.id, id)
        XCTAssertEqual(fixture.coordinator.session.rawTranscript, raw)
        confirm = true
        fixture.coordinator.openTranscript(); await waitForOperation(fixture)
        XCTAssertEqual(confirmations, 2)
        XCTAssertNotEqual(fixture.coordinator.session.id, id)
        XCTAssertEqual(fixture.coordinator.session.phase, .review)
        XCTAssertEqual(fixture.coordinator.session.rawTranscript, "")
        XCTAssertEqual(fixture.coordinator.editedText, "")
        XCTAssertNil(fixture.coordinator.metrics)
        XCTAssertFalse(fixture.coordinator.canStart, "An empty loaded file is still an owned review")
    }

    @MainActor func testNestedPickerCommandsAreRejectedAndCancelDoesNotEraseReview() async throws {
        var owner: AppCoordinator?, panels = 0
        let writes = FixtureValue(0), selected = selected
        let fixture = try CoordinatorFixture(configureEnvironment: { environment in
            environment.chooseTranscriptToSave = { _ in
                panels += 1
                owner?.saveTranscript(); owner?.openTranscript(); owner?.start(); owner?.discard()
                owner?.cancel()
                return selected
            }
            environment.writeTranscript = { _, _ in writes.update { $0 += 1 } }
        })
        owner = fixture.coordinator
        await startRecording(fixture); await stopToReview(fixture)
        fixture.coordinator.editedText = "keep edited review"
        let id = fixture.coordinator.session.id
        fixture.coordinator.saveTranscript()
        XCTAssertEqual(panels, 1)
        XCTAssertEqual(writes.value, 0)
        XCTAssertEqual(fixture.coordinator.session.id, id)
        XCTAssertEqual(fixture.coordinator.editedText, "keep edited review")
        XCTAssertFalse(fixture.coordinator.busy)
        XCTAssertEqual(fixture.resources.counts.value.opened, 1)
    }

    @MainActor func testCancellationAndPrivacyInterruptRejectLateReadButPreserveReview() async throws {
        for privacy in [false, true] {
            let entered = expectation(description: "read entered")
            let read = HeldRead(entered), selected = selected
            var confirmations = 0
            let fixture = try CoordinatorFixture(configureEnvironment: { environment in
                environment.chooseTranscriptToOpen = { _ in selected }
                environment.readTranscript = { _ in read.read() }
                environment.confirmTranscriptReplacement = { _ in confirmations += 1; return true }
            })
            await startRecording(fixture); await stopToReview(fixture)
            fixture.coordinator.editedText = "keep while interrupted"
            let id = fixture.coordinator.session.id
            fixture.coordinator.openTranscript()
            await fulfillment(of: [entered], timeout: 2)
            if privacy { fixture.coordinator.interruptForPrivacy() } else { fixture.coordinator.cancel() }
            XCTAssertTrue(fixture.coordinator.transcriptFilePending, "Admission stays held until actual worker drain")
            XCTAssertFalse(fixture.coordinator.canOpenTranscript)
            XCTAssertEqual(fixture.coordinator.editedText, "keep while interrupted")
            read.resume(); await waitForOperation(fixture)
            XCTAssertEqual(confirmations, 0)
            XCTAssertEqual(fixture.coordinator.session.id, id)
            XCTAssertEqual(fixture.coordinator.editedText, "keep while interrupted")
            XCTAssertEqual(fixture.coordinator.microphone.state, .closed)
            XCTAssertFalse(fixture.coordinator.transcriptFilePending)
        }
    }

    @MainActor func testEditsDuringReadAndCancelDuringConfirmationCannotBeOverwritten() async throws {
        let entered = expectation(description: "read entered")
        let read = HeldRead(entered), selected = selected
        var confirmations = 0
        let fixture = try CoordinatorFixture(configureEnvironment: { environment in
            environment.chooseTranscriptToOpen = { _ in selected }
            environment.readTranscript = { _ in read.read() }
            environment.confirmTranscriptReplacement = { _ in confirmations += 1; return true }
        })
        await startRecording(fixture); await stopToReview(fixture)
        let id = fixture.coordinator.session.id
        fixture.coordinator.openTranscript()
        await fulfillment(of: [entered], timeout: 2)
        fixture.coordinator.editedText = "newer unsaved edit"
        read.resume(); await waitForOperation(fixture)
        XCTAssertEqual(confirmations, 0)
        XCTAssertEqual(fixture.coordinator.session.id, id)
        XCTAssertEqual(fixture.coordinator.editedText, "newer unsaved edit")
        // A separate immediate-reader fixture tests cancellation inside the modal alert.
        var alertOwner: AppCoordinator?
        let alertFixture = try CoordinatorFixture(configureEnvironment: { environment in
            environment.chooseTranscriptToOpen = { _ in selected }
            environment.readTranscript = { _ in "replacement" }
            environment.confirmTranscriptReplacement = { _ in alertOwner?.cancel(); return true }
        })
        alertOwner = alertFixture.coordinator
        await startRecording(alertFixture); await stopToReview(alertFixture)
        alertFixture.coordinator.editedText = "keep after alert cancellation"
        let alertID = alertFixture.coordinator.session.id
        alertFixture.coordinator.openTranscript(); await waitForOperation(alertFixture)
        XCTAssertEqual(alertFixture.coordinator.session.id, alertID)
        XCTAssertEqual(alertFixture.coordinator.editedText, "keep after alert cancellation")
    }

    @MainActor func testCanonicalEquivalentEditDuringReadRejectsReplacementByExactSnapshot() async throws {
        let entered = expectation(description: "second read entered")
        let held = HeldRead(entered)
        let readCount = FixtureValue(0)
        let composed = "\u{00E9}", decomposed = "e\u{0301}"
        var confirmations = 0
        let selected = selected
        let fixture = try CoordinatorFixture(configureEnvironment: { environment in
            environment.chooseTranscriptToOpen = { _ in selected }
            environment.readTranscript = { _ in
                readCount.update { $0 += 1 }
                if readCount.value == 1 { return composed }
                return held.read()
            }
            environment.confirmTranscriptReplacement = { _ in confirmations += 1; return true }
        })
        fixture.coordinator.openTranscript()
        await waitForOperation(fixture)
        let reviewID = fixture.coordinator.session.id
        XCTAssertFalse(fixture.coordinator.hasUnsavedReview)

        fixture.coordinator.openTranscript()
        await fulfillment(of: [entered], timeout: 2)
        fixture.coordinator.editedText = decomposed
        XCTAssertTrue(fixture.coordinator.hasUnsavedReview)
        held.resume()
        await waitForOperation(fixture)

        XCTAssertEqual(fixture.coordinator.session.id, reviewID)
        XCTAssertEqual(Data(fixture.coordinator.editedText.utf8), Data(decomposed.utf8))
        XCTAssertEqual(confirmations, 0, "A changed draft must reject the pending replacement before confirmation")
        XCTAssertEqual(fixture.coordinator.message,
                       "Öffnen nicht übernommen: Die Vorschau wurde inzwischen geändert.")
    }

    @MainActor func testExplicitSaveUsesEditedSnapshotAndRealTemporaryFileWithoutDiscarding() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clavune-save-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("review.txt")
        let fixture = try CoordinatorFixture(configureEnvironment: { environment in
            environment.chooseTranscriptToSave = { _ in target }
            environment.writeTranscript = { try TranscriptFileStore.write($0, to: $1) }
        })
        await startRecording(fixture); await stopToReview(fixture)
        let id = fixture.coordinator.session.id, raw = fixture.coordinator.session.rawTranscript
        for edited in ["edited UTF-8 Straße 👋🏽\n", ""] {
            fixture.coordinator.editedText = edited
            fixture.coordinator.saveTranscript(); await waitForOperation(fixture)
            XCTAssertEqual(try Data(contentsOf: target), Data(edited.utf8))
            XCTAssertEqual(fixture.coordinator.session.id, id)
            XCTAssertEqual(fixture.coordinator.session.rawTranscript, raw)
            XCTAssertEqual(fixture.coordinator.editedText, edited)
            XCTAssertFalse(fixture.coordinator.canStart)
        }
        XCTAssertTrue(fixture.clipboard.calls.isEmpty)
    }

    @MainActor func testWriteFailureAndNewerEditsAreNotReportedAsSavedCurrentReview() async throws {
        let selected = selected
        var fail = true
        let failure = FixtureValue(true), saved = FixtureValue("")
        let entered = expectation(description: "write entered"), gate = DispatchSemaphore(value: 0)
        let fixture = try CoordinatorFixture(configureEnvironment: { environment in
            environment.chooseTranscriptToSave = { _ in failure.value = fail; return selected }
            environment.writeTranscript = { text, _ in
                if failure.value { throw TranscriptFileStore.Failure.invalidFile }
                entered.fulfill(); gate.wait(); saved.value = text
            }
        })
        await startRecording(fixture); await stopToReview(fixture)
        fixture.coordinator.editedText = "before save"
        fixture.coordinator.saveTranscript(); await waitForOperation(fixture)
        XCTAssertEqual(fixture.coordinator.message, "Speichern fehlgeschlagen. Die Vorschau bleibt erhalten.")
        XCTAssertEqual(fixture.coordinator.editedText, "before save")
        fail = false
        fixture.coordinator.saveTranscript(); await fulfillment(of: [entered], timeout: 2)
        fixture.coordinator.editedText = "newer edit"
        gate.signal(); await waitForOperation(fixture)
        XCTAssertEqual(saved.value, "before save")
        XCTAssertEqual(fixture.coordinator.editedText, "newer edit")
        XCTAssertEqual(fixture.coordinator.message, "Textstand gespeichert. Neuere Änderungen sind noch nicht gespeichert.")
    }

    @MainActor func testBusyAndPresentationQARejectPanels() async throws {
        var panels = 0
        let configure: @MainActor (inout CoordinatorEnvironment) -> Void = { environment in
            environment.chooseTranscriptToOpen = { _ in panels += 1; return nil }
            environment.chooseTranscriptToSave = { _ in panels += 1; return nil }
        }
        let fixture = try CoordinatorFixture(configureEnvironment: configure)
        await startRecording(fixture)
        fixture.coordinator.openTranscript(); fixture.coordinator.saveTranscript()
        XCTAssertEqual(panels, 0)
        await cancelAndDrain(fixture)
        let configuration = try AppLaunchConfiguration.parse(environment: ["CLAVUNE_QA_PROFILE": "transcript-files"])
        let qa = try CoordinatorFixture(launchConfiguration: configuration, configureEnvironment: configure)
        qa.coordinator.openTranscript(); qa.coordinator.saveTranscript()
        XCTAssertFalse(qa.coordinator.canOpenTranscript)
        XCTAssertEqual(panels, 0)
    }

    @MainActor func testQuitWaitsForAdmittedReadAndDoesNotAcceptItsLateText() async throws {
        let entered = expectation(description: "read entered")
        // No timers/polling or real process termination.
        let held = HeldRead(entered), selected = selected
        let fixture = try CoordinatorFixture(configureEnvironment: { environment in
            environment.chooseTranscriptToOpen = { _ in selected }
            environment.readTranscript = { _ in held.read() }
        })
        fixture.coordinator.openTranscript(); await fulfillment(of: [entered], timeout: 2)
        fixture.terminated = expectation(description: "quit after file drain")
        fixture.coordinator.quit()
        XCTAssertEqual(fixture.terminationCalls, 0)
        XCTAssertTrue(fixture.coordinator.operationPending)
        held.resume()
        await fulfillment(of: [try XCTUnwrap(fixture.terminated)], timeout: 2)
        XCTAssertEqual(fixture.coordinator.session.rawTranscript, "")
        XCTAssertEqual(fixture.coordinator.editedText, "")
        XCTAssertEqual(fixture.quitTrace.last, .terminationRequested)
        XCTAssertFalse(fixture.coordinator.operationPending)
    }
}
