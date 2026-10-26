import Foundation
import XCTest
@testable import ClavuneCore

@MainActor
private final class FakeSelectedTextBoundary: ConditionalSelectedTextBoundary {
    var token: TargetToken?
    var snapshots = 0
    var dispatches = 0
    var cancelledObservations = 0
    var mutations = 0
    var lastWrittenText: String?
    var shouldHold = false
    var shouldThrow = false
    var outcome: InsertionOutcome = .verified
    var onDispatch: (() -> Void)?
    private var held: CheckedContinuation<Void, Never>?
    private var releaseWhenHeld = false

    init(token: TargetToken?) { self.token = token }
    func cancelObservation() { cancelledObservations += 1 }
    func currentTarget() throws -> TargetToken? {
        snapshots += 1
        return token
    }
    func writeSelectedText(_ text: String, expecting expected: TargetToken,
                           lease: InsertionMutationLease) async throws -> InsertionOutcome {
        dispatches += 1
        if shouldHold {
            await withCheckedContinuation { continuation in
                if releaseWhenHeld {
                    releaseWhenHeld = false
                    continuation.resume()
                } else {
                    held = continuation
                }
                onDispatch?()
            }
        } else {
            onDispatch?()
        }
        if shouldThrow { throw SyntheticWriteError() }
        // The synthetic boundary performs its own final check without an await
        // between validation and its one pretend mutation. Real AX is unproven.
        guard lease.isValid, token == expected else { return .failedBeforeMutation }
        mutations += 1
        lastWrittenText = text
        return outcome
    }
    func release() {
        let continuation = held
        held = nil
        if let continuation { continuation.resume() }
        else { releaseWhenHeld = true }
    }
}

private struct SyntheticWriteError: Error {}

final class DeferredSelectedTextInsertionTests: XCTestCase {
    private func target(process: UUID = UUID(), window: UUID = UUID(), field: UUID = UUID(),
                        selection: NSRange = NSRange(location: 3, length: 0),
                        selectionRevision: UInt64 = 0,
                        classification: TargetToken.Classification = .supportedText,
                        secure: Bool = false, writable: Bool = true,
                        validated: Bool = true) -> TargetToken {
        TargetToken(processIdentity: process, windowIdentity: window, fieldIdentity: field,
            interactionGeneration: 0, selection: selection, selectionRevision: selectionRevision,
            classification: classification, editable: true, enabled: true,
            selectedTextWritable: writable, adapterValidated: validated, secureInput: secure)
    }

    @MainActor func testDefaultDisabledDoesNotEvenProbeTarget() async {
        let original = target(), boundary = FakeSelectedTextBoundary(token: nil)
        let controller = DeferredSelectedTextInsertion(session: UUID(), revision: 1,
            reviewedText: "synthetic text", original: original, boundary: boundary,
            registry: InsertionAttemptRegistry())
        let result = await controller.attempt(session: UUID(), revision: 1,
            currentReviewText: "synthetic text", intent: .insertAtCaret)
        XCTAssertEqual(result, .disabled)
        XCTAssertEqual(boundary.snapshots, 0)
        XCTAssertEqual(boundary.dispatches, 0)
    }

    @MainActor func testSingleSharedRegistryAllowsOneConditionalMutationOnly() async {
        let id = UUID(), original = target()
        let boundary = FakeSelectedTextBoundary(token: original)
        let registry = InsertionAttemptRegistry()
        let first = DeferredSelectedTextInsertion(session: id, revision: 2,
            reviewedText: "alpha", original: original, boundary: boundary, registry: registry,
            mode: .syntheticFixtureOnly)
        let duplicate = DeferredSelectedTextInsertion(session: id, revision: 2,
            reviewedText: "alpha", original: original, boundary: boundary, registry: registry,
            mode: .syntheticFixtureOnly)
        let accepted = await first.attempt(session: id, revision: 2,
            currentReviewText: "alpha", intent: .insertAtCaret)
        let replay = await first.attempt(session: id, revision: 2,
            currentReviewText: "alpha", intent: .insertAtCaret)
        let cloned = await duplicate.attempt(session: id, revision: 2,
            currentReviewText: "alpha", intent: .insertAtCaret)
        XCTAssertEqual(accepted, .finished(.verified))
        XCTAssertEqual(replay, .blocked(.alreadyAttempted))
        XCTAssertEqual(cloned, .blocked(.alreadyAttempted))
        XCTAssertEqual(boundary.dispatches, 1)
        XCTAssertEqual(boundary.mutations, 1)
        XCTAssertEqual(boundary.lastWrittenText, "alpha")
    }

    @MainActor func testObservedFocusABAReturnAndSelectionChangeStayInvalidated() async {
        let id = UUID(), process = UUID(), window = UUID(), field = UUID()
        let original = target(process: process, window: window, field: field)
        let changed = target(process: process, window: window, field: field, selectionRevision: 1)
        let boundary = FakeSelectedTextBoundary(token: original)
        let controller = DeferredSelectedTextInsertion(session: id, revision: 1,
            reviewedText: "alpha", original: original, boundary: boundary,
            registry: InsertionAttemptRegistry(), mode: .syntheticFixtureOnly)
        controller.observe(changed)
        controller.observe(original) // returning to the same token cannot heal the lease
        let result = await controller.attempt(session: id, revision: 1,
            currentReviewText: "alpha", intent: .insertAtCaret)
        XCTAssertEqual(result, .blocked(.targetChanged))
        XCTAssertEqual(boundary.snapshots, 0)
        XCTAssertEqual(boundary.dispatches, 0)
    }

    @MainActor func testFinalSnapshotRejectsChangedOrUnknownTargetWithoutWrite() async {
        let id = UUID(), original = target()
        let boundary = FakeSelectedTextBoundary(token: target())
        let controller = DeferredSelectedTextInsertion(session: id, revision: 1,
            reviewedText: "alpha", original: original, boundary: boundary,
            registry: InsertionAttemptRegistry(), mode: .syntheticFixtureOnly)
        let result = await controller.attempt(session: id, revision: 1,
            currentReviewText: "alpha", intent: .insertAtCaret)
        XCTAssertEqual(result, .blocked(.targetChanged))
        boundary.token = original
        let replay = await controller.attempt(session: id, revision: 1,
            currentReviewText: "alpha", intent: .insertAtCaret)
        XCTAssertEqual(replay, .blocked(.targetChanged))
        XCTAssertEqual(boundary.dispatches, 0)
    }

    @MainActor func testSecureUnknownTerminalUnsupportedAndSelectionPolicyRemainClosed() async {
        for original in [target(classification: .secure), target(classification: .unknown),
                         target(classification: .terminal), target(secure: true),
                         target(validated: false)] {
            let id = UUID(), boundary = FakeSelectedTextBoundary(token: original)
            let controller = DeferredSelectedTextInsertion(session: id, revision: 1,
                reviewedText: "alpha", original: original, boundary: boundary,
                registry: InsertionAttemptRegistry(), mode: .syntheticFixtureOnly)
            let result = await controller.attempt(session: id, revision: 1,
                currentReviewText: "alpha", intent: .insertAtCaret)
            XCTAssertEqual(result, .blocked(.unsafeTarget))
            XCTAssertEqual(boundary.dispatches, 0)
        }
        let selected = target(selection: NSRange(location: 2, length: 4))
        let id = UUID(), boundary = FakeSelectedTextBoundary(token: selected)
        let controller = DeferredSelectedTextInsertion(session: id, revision: 1,
            reviewedText: "alpha", original: selected, boundary: boundary,
            registry: InsertionAttemptRegistry(), mode: .syntheticFixtureOnly)
        let implicitReplacement = await controller.attempt(session: id, revision: 1,
            currentReviewText: "alpha", intent: .insertAtCaret)
        XCTAssertEqual(implicitReplacement, .blocked(.reviewRequired))
        let explicitReplacement = await controller.attempt(session: id, revision: 1,
            currentReviewText: "alpha", intent: .replaceSelection)
        XCTAssertEqual(explicitReplacement, .finished(.verified))
        XCTAssertEqual(boundary.mutations, 1)
    }

    @MainActor func testReviewSessionRevisionAndExactUTF8AreBoundBeforeReservation() async {
        let id = UUID(), original = target()
        let boundary = FakeSelectedTextBoundary(token: original)
        let controller = DeferredSelectedTextInsertion(session: id, revision: 3,
            reviewedText: "e\u{301}", original: original, boundary: boundary,
            registry: InsertionAttemptRegistry(), mode: .syntheticFixtureOnly)
        let normalized = await controller.attempt(session: id, revision: 3,
            currentReviewText: "é", intent: .insertAtCaret)
        XCTAssertEqual(normalized, .reviewChanged)
        let staleRevision = await controller.attempt(session: id, revision: 4,
            currentReviewText: "e\u{301}", intent: .insertAtCaret)
        XCTAssertEqual(staleRevision, .blocked(.targetChanged))
        let staleSession = await controller.attempt(session: UUID(), revision: 3,
            currentReviewText: "e\u{301}", intent: .insertAtCaret)
        XCTAssertEqual(staleSession, .blocked(.targetChanged))
        XCTAssertEqual(boundary.dispatches, 0)
    }

    @MainActor func testCancelDuringSuspendedBoundaryRevokesLateWriteAndRetry() async {
        let id = UUID(), original = target()
        let boundary = FakeSelectedTextBoundary(token: original)
        boundary.shouldHold = true
        let controller = DeferredSelectedTextInsertion(session: id, revision: 1,
            reviewedText: "alpha", original: original, boundary: boundary,
            registry: InsertionAttemptRegistry(), mode: .syntheticFixtureOnly)
        let dispatched = expectation(description: "synthetic conditional write entered")
        boundary.onDispatch = { dispatched.fulfill() }
        let pending = Task { await controller.attempt(session: id, revision: 1,
            currentReviewText: "alpha", intent: .insertAtCaret) }
        await fulfillment(of: [dispatched], timeout: 2)
        controller.cancel()
        XCTAssertEqual(boundary.cancelledObservations, 1)
        boundary.release()
        let result = await pending.value
        XCTAssertEqual(result, .finished(.outcomeUnknown))
        XCTAssertEqual(boundary.mutations, 0)
        let retry = await controller.attempt(session: id, revision: 1,
            currentReviewText: "alpha", intent: .insertAtCaret)
        XCTAssertEqual(retry, .blocked(.alreadyAttempted))
        XCTAssertEqual(boundary.dispatches, 1)
    }

    @MainActor func testReviewEditDuringSuspendedBoundaryRevokesLateWrite() async {
        let id = UUID(), original = target()
        let boundary = FakeSelectedTextBoundary(token: original)
        boundary.shouldHold = true
        let controller = DeferredSelectedTextInsertion(session: id, revision: 1,
            reviewedText: "alpha", original: original, boundary: boundary,
            registry: InsertionAttemptRegistry(), mode: .syntheticFixtureOnly)
        let dispatched = expectation(description: "synthetic conditional write entered")
        boundary.onDispatch = { dispatched.fulfill() }
        let pending = Task { await controller.attempt(session: id, revision: 1,
            currentReviewText: "alpha", intent: .insertAtCaret) }
        await fulfillment(of: [dispatched], timeout: 2)
        controller.reviewDidChange()
        XCTAssertEqual(boundary.cancelledObservations, 1)
        boundary.release()
        let result = await pending.value
        XCTAssertEqual(result, .finished(.outcomeUnknown))
        XCTAssertEqual(boundary.mutations, 0)
        let retry = await controller.attempt(session: id, revision: 1,
            currentReviewText: "changed", intent: .insertAtCaret)
        XCTAssertEqual(retry, .blocked(.alreadyAttempted))
    }

    @MainActor func testThrownOrUnknownWriteOutcomeCannotBeRetried() async {
        let id = UUID(), original = target()
        let boundary = FakeSelectedTextBoundary(token: original)
        boundary.shouldThrow = true
        let controller = DeferredSelectedTextInsertion(session: id, revision: 1,
            reviewedText: "alpha", original: original, boundary: boundary,
            registry: InsertionAttemptRegistry(), mode: .syntheticFixtureOnly)
        let failure = await controller.attempt(session: id, revision: 1,
            currentReviewText: "alpha", intent: .insertAtCaret)
        XCTAssertEqual(failure, .finished(.outcomeUnknown))
        boundary.shouldThrow = false
        let retry = await controller.attempt(session: id, revision: 1,
            currentReviewText: "alpha", intent: .insertAtCaret)
        XCTAssertEqual(retry, .blocked(.alreadyAttempted))
        XCTAssertEqual(boundary.dispatches, 1)
        XCTAssertEqual(boundary.mutations, 0)
    }

    @MainActor func testDispatchedUnverifiedRemainsDistinctAndCannotBeRetried() async {
        let id = UUID(), original = target()
        let boundary = FakeSelectedTextBoundary(token: original)
        boundary.outcome = .dispatchedUnverified
        let controller = DeferredSelectedTextInsertion(session: id, revision: 1,
            reviewedText: "alpha", original: original, boundary: boundary,
            registry: InsertionAttemptRegistry(), mode: .syntheticFixtureOnly)
        let result = await controller.attempt(session: id, revision: 1,
            currentReviewText: "alpha", intent: .insertAtCaret)
        XCTAssertEqual(result, .finished(.dispatchedUnverified))
        let retry = await controller.attempt(session: id, revision: 1,
            currentReviewText: "alpha", intent: .insertAtCaret)
        XCTAssertEqual(retry, .blocked(.alreadyAttempted))
        XCTAssertEqual(boundary.mutations, 1)
    }
}
