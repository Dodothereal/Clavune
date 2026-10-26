import Foundation

/// A source-only seam for later, explicitly approved target-app research.
/// The AX candidate is unreferenced and there is no production call site.
/// A future boundary must revalidate the entire token AND lease immediately
/// before its one SelectedText mutation, and report uncertainty after dispatch.
@MainActor
protocol ConditionalSelectedTextBoundary {
    func currentTarget() throws -> TargetToken?
    func cancelObservation()
    func writeSelectedText(_ text: String, expecting target: TargetToken,
                           lease: InsertionMutationLease) async throws -> InsertionOutcome
}

/// Cancellation and every observed target change permanently revoke this lease.
/// It cannot make a cross-process AX read/write atomic; that remains an unmet
/// production requirement, not a capability claimed by these fake-boundary tests.
@MainActor
final class InsertionMutationLease {
    private(set) var isValid = true
    fileprivate func invalidate() { isValid = false }
}

/// A single owner must retain one registry for all attempts in an app process.
/// Per-controller fences alone can be duplicated, permitting two writes.
@MainActor
final class InsertionAttemptRegistry {
    private struct Key: Hashable { let session: UUID; let revision: UInt64 }
    private var attempted = Set<Key>()

    func hasAttempt(session: UUID, revision: UInt64) -> Bool {
        attempted.contains(Key(session: session, revision: revision))
    }

    fileprivate func reserve(session: UUID, revision: UInt64) -> Bool {
        attempted.insert(Key(session: session, revision: revision)).inserted
    }
}

enum DeferredInsertionResult: Equatable {
    case disabled
    case cancelled
    case reviewChanged
    case blocked(InsertionDecision)
    case finished(InsertionOutcome)
}

/// Disabled by default and unreferenced by the app. `syntheticFixtureOnly`
/// exercises admission against injected fakes; it is not an AX permission gate.
@MainActor
final class DeferredSelectedTextInsertion {
    enum Mode { case disabled, syntheticFixtureOnly }

    private let mode: Mode
    private let original: TargetToken
    private let reviewedUTF8: [UInt8]
    private let boundary: any ConditionalSelectedTextBoundary
    private let registry: InsertionAttemptRegistry
    private var fence: InsertionFence
    private let lease = InsertionMutationLease()
    private var invalidated = false
    private var reviewInvalidated = false
    private var cancelled = false

    init(session: UUID, revision: UInt64, reviewedText: String, original: TargetToken,
         boundary: any ConditionalSelectedTextBoundary, registry: InsertionAttemptRegistry,
         mode: Mode = .disabled) {
        self.mode = mode
        self.original = original
        self.reviewedUTF8 = Array(reviewedText.utf8)
        self.boundary = boundary
        self.registry = registry
        self.fence = InsertionFence(session: session, revision: revision)
    }

    /// A future caller must feed every focus/window/field/selection/secure-input/
    /// capability change. Tests exercise the latch, not notification coverage.
    /// Unknown observation and observed A -> B -> A stay invalid forever.
    func observe(_ token: TargetToken?) {
        guard token == original else { invalidate(); return }
    }

    func observationLost() { invalidate() }

    /// Review edits or session/revision replacement revoke an in-flight lease;
    /// checking only at attempt entry would permit a late stale-text write.
    func reviewDidChange() {
        reviewInvalidated = true
        invalidate()
    }

    func sessionEnded() { cancel() }

    func cancel() {
        // A future owner must call this for task cancellation as well as user
        // Cancel; Task.cancel() alone does not synchronously revoke this lease.
        cancelled = true
        invalidate()
    }

    private func invalidate() {
        invalidated = true
        lease.invalidate()
        boundary.cancelObservation()
    }

    func attempt(session: UUID, revision: UInt64, currentReviewText: String,
                 intent: InsertionIntent) async -> DeferredInsertionResult {
        guard mode == .syntheticFixtureOnly else { return .disabled }
        guard !fence.attempted, !registry.hasAttempt(session: session, revision: revision) else {
            return .blocked(.alreadyAttempted)
        }
        guard !cancelled else { return .cancelled }
        guard !reviewInvalidated else { return .reviewChanged }
        guard !invalidated else { return .blocked(.targetChanged) }
        guard Array(currentReviewText.utf8) == reviewedUTF8 else { return .reviewChanged }
        guard !reviewedUTF8.isEmpty else { return .blocked(.reviewRequired) }

        let current: TargetToken
        do {
            guard let observed = try boundary.currentTarget() else {
                invalidate(); return .blocked(.targetChanged)
            }
            current = observed
        } catch {
            invalidate(); return .blocked(.targetChanged)
        }
        observe(current)
        guard !invalidated else { return .blocked(.targetChanged) }
        let decision = fence.reserve(session: session, revision: revision,
                                     original: original, current: current, intent: intent)
        guard decision == .allowSelectedText else { return .blocked(decision) }
        guard registry.reserve(session: session, revision: revision) else {
            return .blocked(.alreadyAttempted)
        }

        // There is no await between reservation and dispatch. Once dispatched,
        // cancellation is not a rollback and no retry/fallback is authorized.
        let outcome: InsertionOutcome
        do {
            outcome = try await boundary.writeSelectedText(currentReviewText,
                expecting: original, lease: lease)
        } catch {
            outcome = .outcomeUnknown
        }
        let finalOutcome: InsertionOutcome = lease.isValid ? outcome : .outcomeUnknown
        fence.finish(finalOutcome)
        return .finished(finalOutcome)
    }
}
