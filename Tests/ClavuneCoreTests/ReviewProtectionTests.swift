import AppKit
import XCTest
@testable import ClavuneApp
@testable import ClavuneCore

/// Actual coordinator commands and production clipboard policy, with synthetic
/// capture/inference and an in-memory write sink. No general clipboard or microphone.
final class ReviewProtectionTests: UIFixtureAssertions {
    @MainActor func testNewStartCannotEraseEditedReviewOrAdmitResources() async throws {
        let fixture = try CoordinatorFixture()
        await startRecording(fixture); await stopToReview(fixture)
        let id = fixture.coordinator.session.id
        let raw = fixture.coordinator.session.rawTranscript
        let metrics = fixture.coordinator.metrics?.session
        fixture.coordinator.editedText = "Edited review — Grüß dich"
        fixture.throwCancellationAllocation = true
        XCTAssertTrue(fixture.coordinator.hasPendingReview)
        XCTAssertFalse(fixture.coordinator.canStart)
        fixture.coordinator.start(); fixture.coordinator.start()
        XCTAssertEqual(fixture.coordinator.session.id, id)
        XCTAssertEqual(fixture.coordinator.session.phase, .review)
        XCTAssertEqual(fixture.coordinator.session.rawTranscript, raw)
        XCTAssertEqual(fixture.coordinator.editedText, "Edited review — Grüß dich")
        XCTAssertEqual(fixture.coordinator.metrics?.session, metrics)
        XCTAssertEqual(fixture.cancellationAllocationCalls, 1)
        XCTAssertEqual(fixture.inference.counts.value.loads, 1)
        XCTAssertEqual(fixture.resources.counts.value.opened, 1)
        XCTAssertTrue(fixture.clipboard.calls.isEmpty)
    }
    @MainActor func testEmptyEditedAndEmptyRawReviewsStillRequireExplicitDiscard() async throws {
        for transcript in ["Original result", ""] {
            let fixture = try CoordinatorFixture()
            fixture.inference.transcript = transcript
            await startRecording(fixture); await stopToReview(fixture)
            fixture.coordinator.editedText = ""
            let id = fixture.coordinator.session.id
            fixture.coordinator.start()
            XCTAssertFalse(fixture.coordinator.canStart)
            XCTAssertEqual(fixture.coordinator.session.phase, .review)
            XCTAssertEqual(fixture.coordinator.session.id, id)
            XCTAssertEqual(fixture.coordinator.session.rawTranscript, transcript)
            XCTAssertEqual(fixture.cancellationAllocationCalls, 1)
            XCTAssertEqual(fixture.inference.counts.value.loads, 1)
        }
    }
    @MainActor func testHoldAndToggleHotkeyCannotReplacePendingReview() async throws {
        let fixture = try CoordinatorFixture()
        fixture.coordinator.setHotkeyEnabled(true)
        let registration = try XCTUnwrap(fixture.hotkeyRegistrar.registrations.first)
        await startRecording(fixture); await stopToReview(fixture)
        fixture.coordinator.editedText = "Keep this draft"
        let id = fixture.coordinator.session.id
        for hold in [true, false] {
            fixture.coordinator.holdToTalk = hold
            registration.send(down: true); registration.send(down: false)
            registration.send(down: true); registration.send(down: false)
            XCTAssertEqual(fixture.coordinator.session.phase, .review)
            XCTAssertEqual(fixture.coordinator.session.id, id)
            XCTAssertEqual(fixture.coordinator.editedText, "Keep this draft")
        }
        XCTAssertEqual(fixture.cancellationAllocationCalls, 1)
        XCTAssertEqual(fixture.resources.counts.value.opened, 1)
        XCTAssertTrue(fixture.clipboard.calls.isEmpty)
        fixture.coordinator.setHotkeyEnabled(false)
    }
    @MainActor func testCoordinatorCopyUsesEditedPlainTextHostOnlyAndKeepsReview() async throws {
        let fixture = try CoordinatorFixture()
        await startRecording(fixture); await stopToReview(fixture)
        let raw = fixture.coordinator.session.rawTranscript
        let id = fixture.coordinator.session.id
        let edited = "Edited 👋🏽\nStraße – synthetic only"
        fixture.coordinator.editedText = edited
        fixture.coordinator.copy()
        XCTAssertEqual(fixture.clipboard.calls, [.prepare([.currentHostOnly]), .write(edited, .string)])
        XCTAssertEqual(fixture.coordinator.message,
                       "Bewusst kopiert. Die Zwischenablage ist für andere lokale Apps lesbar.")
        XCTAssertEqual(fixture.coordinator.session.id, id)
        XCTAssertEqual(fixture.coordinator.session.rawTranscript, raw)
        XCTAssertEqual(fixture.coordinator.editedText, edited)
        fixture.coordinator.start()
        XCTAssertEqual(fixture.coordinator.session.phase, .review)
        XCTAssertFalse(fixture.coordinator.canStart, "Successful Copy is not implicit discard")
        fixture.coordinator.copy()
        XCTAssertEqual(fixture.clipboard.calls.count, 4, "Each deliberate Copy has exactly one write")
    }
    @MainActor func testCopyFailureAndInvalidCopyLeaveReviewUntouched() async throws {
        let fixture = try CoordinatorFixture()
        fixture.coordinator.copy()
        XCTAssertTrue(fixture.clipboard.calls.isEmpty)
        await startRecording(fixture)
        fixture.coordinator.copy()
        XCTAssertTrue(fixture.clipboard.calls.isEmpty)
        await stopToReview(fixture)
        let raw = fixture.coordinator.session.rawTranscript
        let id = fixture.coordinator.session.id
        fixture.coordinator.editedText = "Retain after failure"
        fixture.clipboard.acceptsWrite = false
        fixture.coordinator.copy()
        XCTAssertEqual(fixture.clipboard.calls,
                       [.prepare([.currentHostOnly]), .write("Retain after failure", .string)])
        XCTAssertEqual(fixture.coordinator.message, "Kopieren fehlgeschlagen. Text bleibt in der Vorschau.")
        XCTAssertEqual(fixture.coordinator.session.id, id)
        XCTAssertEqual(fixture.coordinator.editedText, "Retain after failure")
        XCTAssertEqual(fixture.coordinator.session.rawTranscript, raw)
        fixture.coordinator.editedText = ""
        fixture.coordinator.copy()
        XCTAssertEqual(fixture.clipboard.calls.count, 2, "Empty edit must not clear any clipboard")
        await cancelAndDrain(fixture)
        fixture.coordinator.copy()
        XCTAssertEqual(fixture.clipboard.calls.count, 2)
    }
    @MainActor func testExplicitDiscardUnlocksFreshRecordingWithoutImplicitClipboardWrite() async throws {
        let fixture = try CoordinatorFixture()
        await startRecording(fixture); await stopToReview(fixture)
        let previousID = fixture.coordinator.session.id
        fixture.coordinator.editedText = "Discard deliberately"
        fixture.coordinator.discard()
        XCTAssertFalse(fixture.coordinator.hasPendingReview)
        XCTAssertTrue(fixture.coordinator.canStart)
        XCTAssertTrue(fixture.coordinator.editedText.isEmpty)
        XCTAssertTrue(fixture.coordinator.session.rawTranscript.isEmpty)
        XCTAssertNil(fixture.coordinator.metrics)
        await startRecording(fixture)
        XCTAssertNotEqual(fixture.coordinator.session.id, previousID)
        XCTAssertEqual(fixture.cancellationAllocationCalls, 2)
        XCTAssertEqual(fixture.resources.counts.value.opened, 2)
        XCTAssertTrue(fixture.clipboard.calls.isEmpty)
        await cancelAndDrain(fixture)
    }
}
