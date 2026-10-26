import Foundation
import XCTest
@testable import ClavuneApp
@testable import ClavuneCore

/// Actual coordinator admission/cancellation with fake unload delivery only.
/// No model bytes, inference load/decode, microphone, real panel or user file I/O.
final class ModelUnloadResultOwnershipTests: UIFixtureAssertions {
    private enum FixtureFailure: Error { case expectedBoundaryNotReached }

    @MainActor private func reached(_ expectations: [XCTestExpectation]) async throws {
        guard await XCTWaiter.fulfillment(of: expectations, timeout: 3) == .completed else {
            XCTFail("The controlled coordinator boundary did not complete")
            throw FixtureFailure.expectedBoundaryNotReached
        }
    }

    @MainActor private func assertNoResourceEffects(_ fixture: CoordinatorFixture) {
        XCTAssertEqual(fixture.coordinator.microphone.state, .closed)
        XCTAssertEqual(fixture.resources.counts.value.constructed, 0)
        XCTAssertEqual(fixture.resources.counts.value.opened, 0)
        XCTAssertEqual(fixture.inference.counts.value.loads, 0)
        XCTAssertEqual(fixture.inference.counts.value.decodes, 0)
        XCTAssertEqual(fixture.permissionCalls, 0)
        XCTAssertEqual(fixture.pickerCalls, 0)
        XCTAssertEqual(fixture.terminationCalls, 0)
        XCTAssertTrue(fixture.hotkeyRegistrar.shortcuts.isEmpty)
        XCTAssertTrue(fixture.clipboard.calls.isEmpty)
    }

    @MainActor private func cancelAndDrainFirstUnload(_ fixture: CoordinatorFixture) async throws {
        let gate = ControlledDelivery()
        let entered = expectation(description: "first fake unload entered")
        let observedCancellation = FixtureValue(false)
        fixture.inference.unloadGate = gate
        fixture.inference.onUnload = entered
        fixture.inference.onUnloadCompleted = { observedCancellation.value = Task.isCancelled }
        defer { Task { await gate.release() } }
        fixture.coordinator.unload()
        try await reached([entered])
        await gate.waitUntilSuspended()
        XCTAssertTrue(fixture.coordinator.operationPending)
        XCTAssertEqual(fixture.inference.counts.value.unloads, 1)
        fixture.coordinator.cancel()
        XCTAssertEqual(fixture.coordinator.session.phase, .cancelled)
        XCTAssertTrue(fixture.coordinator.busy)
        // A retry while the old worker still owns admission must be rejected.
        fixture.coordinator.unload()
        XCTAssertEqual(fixture.inference.counts.value.unloads, 1)
        XCTAssertEqual(fixture.coordinator.session.phase, .cancelled)
        let drained = expectation(description: "first cancelled unload drained")
        let closed = expectation(description: "first cancellation close acknowledged")
        fixture.observeOperationFinished(drained)
        fixture.observeCloseFinished(closed)
        await gate.release()
        try await reached([drained, closed])
        fixture.inference.unloadGate = nil
        fixture.inference.onUnload = nil
        fixture.inference.onUnloadCompleted = nil
        XCTAssertTrue(observedCancellation.value)
        XCTAssertFalse(fixture.coordinator.operationPending)
        XCTAssertFalse(fixture.coordinator.closePending)
        XCTAssertFalse(fixture.coordinator.busy)
        XCTAssertEqual(fixture.coordinator.session.phase, .cancelled)
        XCTAssertEqual(fixture.coordinator.message, "Abgebrochen. Mikrofon geschlossen.")
        assertNoResourceEffects(fixture)
    }

    @MainActor func testSuccessfulUnloadAfterDrainedCancellationKeepsItsOwnResult() async throws {
        let fixture = try CoordinatorFixture(processUsageSnapshot: { nil })
        let selectedModel = fixture.coordinator.model?.sha256
        try await cancelAndDrainFirstUnload(fixture)
        fixture.coordinator.unload()
        XCTAssertEqual(fixture.coordinator.session.phase, .cancelled,
                       "Memory-only unload does not replace the dictation session")
        let finished = expectation(description: "fresh unload finished")
        fixture.observeOperationFinished(finished)
        try await reached([finished])
        XCTAssertEqual(fixture.coordinator.message, "Modell aus dem Arbeitsspeicher entladen.",
                       "The old cancellation must not replace a successful new action's result")
        XCTAssertEqual(fixture.coordinator.session.phase, .cancelled)
        XCTAssertEqual(fixture.inference.counts.value.unloads, 2)
        XCTAssertEqual(fixture.coordinator.model?.sha256, selectedModel,
                       "Unloading memory must not deselect the verified model")
        XCTAssertFalse(fixture.coordinator.busy)
        assertNoResourceEffects(fixture)
    }

    @MainActor func testFreshCancellationDuringUnloadRetryStillWins() async throws {
        let fixture = try CoordinatorFixture(processUsageSnapshot: { nil })
        let selectedModel = fixture.coordinator.model?.sha256
        try await cancelAndDrainFirstUnload(fixture)
        let gate = ControlledDelivery()
        let entered = expectation(description: "retry fake unload entered")
        let observedCancellation = FixtureValue(false)
        fixture.inference.unloadGate = gate
        fixture.inference.onUnload = entered
        fixture.inference.onUnloadCompleted = { observedCancellation.value = Task.isCancelled }
        defer { Task { await gate.release() } }
        fixture.coordinator.unload()
        try await reached([entered])
        await gate.waitUntilSuspended()
        fixture.coordinator.cancel()
        let drained = expectation(description: "fresh cancelled unload drained")
        let closed = expectation(description: "fresh cancellation close acknowledged")
        fixture.observeOperationFinished(drained)
        fixture.observeCloseFinished(closed)
        // Close first, while unload still owns the worker. An unconditional
        // message-preserving defer would strand this intermediate drain message.
        try await reached([closed])
        XCTAssertTrue(fixture.coordinator.operationPending)
        XCTAssertTrue(fixture.coordinator.busy)
        XCTAssertEqual(fixture.coordinator.message,
                       "Mikrofon geschlossen; Abbruch der laufenden Arbeit wird abgewartet …")
        await gate.release()
        try await reached([drained])
        XCTAssertTrue(observedCancellation.value)
        XCTAssertEqual(fixture.coordinator.session.phase, .cancelled)
        XCTAssertEqual(fixture.coordinator.message, "Abgebrochen. Mikrofon geschlossen.")
        XCTAssertEqual(fixture.inference.counts.value.unloads, 2)
        XCTAssertEqual(fixture.coordinator.model?.sha256, selectedModel)
        XCTAssertFalse(fixture.coordinator.operationPending)
        XCTAssertFalse(fixture.coordinator.closePending)
        XCTAssertFalse(fixture.coordinator.busy)
        assertNoResourceEffects(fixture)
    }

    @MainActor func testSuccessfulUnloadPreservesReviewIdentityEditsAndSavepoint() async throws {
        let original = "Synthetic saved review — Grüße"
        let fixture = try CoordinatorFixture(processUsageSnapshot: { nil }, configureEnvironment: { environment in
            environment.chooseTranscriptToOpen = { _ in URL(fileURLWithPath: "/synthetic-unload-review-never-opened.txt") }
            environment.readTranscript = { _ in original }
        })
        fixture.coordinator.openTranscript()
        let opened = expectation(description: "synthetic review opened")
        fixture.observeOperationFinished(opened)
        try await reached([opened])
        let reviewID = try XCTUnwrap(fixture.coordinator.session.id)
        let selectedModel = fixture.coordinator.model?.sha256
        for (index, text) in [original, "Synthetic newer edit — 保留"].enumerated() {
            fixture.coordinator.editedText = text
            let wasUnsaved = fixture.coordinator.hasUnsavedReview
            XCTAssertEqual(wasUnsaved, index == 1)
            fixture.coordinator.unload()
            XCTAssertEqual(fixture.coordinator.session.phase, .review)
            let finished = expectation(description: "review-preserving unload finished \(index)")
            fixture.observeOperationFinished(finished)
            try await reached([finished])
            XCTAssertEqual(fixture.coordinator.message, "Modell aus dem Arbeitsspeicher entladen.")
            XCTAssertEqual(fixture.coordinator.session.phase, .review)
            XCTAssertEqual(fixture.coordinator.session.id, reviewID)
            XCTAssertEqual(fixture.coordinator.session.rawTranscript, original)
            XCTAssertEqual(fixture.coordinator.editedText, text)
            XCTAssertEqual(fixture.coordinator.hasUnsavedReview, wasUnsaved)
            XCTAssertEqual(fixture.coordinator.model?.sha256, selectedModel)
            XCTAssertEqual(fixture.inference.counts.value.unloads, index + 1)
            XCTAssertFalse(fixture.coordinator.busy)
            assertNoResourceEffects(fixture)
        }
    }
}
