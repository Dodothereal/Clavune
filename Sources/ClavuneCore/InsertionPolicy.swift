import Foundation

/// Policy-only M2 foundation. No cross-process AX writes or synthetic paste adapter is enabled.
public struct TargetToken: Equatable, Sendable {
    public enum Classification: Sendable { case supportedText, secure, terminal, unknown }
    public let processIdentity: UUID
    public let windowIdentity: UUID
    public let fieldIdentity: UUID
    public let interactionGeneration: UInt64
    public let selection: NSRange
    public let selectionRevision: UInt64
    public let classification: Classification
    public let editable: Bool
    public let enabled: Bool
    public let selectedTextWritable: Bool
    public let adapterValidated: Bool
    public let secureInput: Bool
    public init(processIdentity: UUID, windowIdentity: UUID, fieldIdentity: UUID,
                interactionGeneration: UInt64, selection: NSRange, selectionRevision: UInt64,
                classification: Classification, editable: Bool, enabled: Bool,
                selectedTextWritable: Bool, adapterValidated: Bool, secureInput: Bool) {
        self.processIdentity = processIdentity; self.windowIdentity = windowIdentity
        self.fieldIdentity = fieldIdentity; self.interactionGeneration = interactionGeneration
        self.selection = selection; self.selectionRevision = selectionRevision
        self.classification = classification; self.editable = editable; self.enabled = enabled
        self.selectedTextWritable = selectedTextWritable; self.adapterValidated = adapterValidated
        self.secureInput = secureInput
    }
}
public enum InsertionIntent: Sendable { case reviewOnly, insertAtCaret, replaceSelection }
public enum InsertionDecision: Equatable, Sendable {
    case allowSelectedText, reviewRequired, targetChanged, unsafeTarget, unsupportedSelection, unsupportedCapability, alreadyAttempted
}
public enum InsertionOutcome: Equatable, Sendable { case verified, dispatchedUnverified, outcomeUnknown, failedBeforeMutation }

/// One bounded commit fence per session/revision. No repeat is allowed after reservation.
public struct InsertionFence: Sendable {
    public let session: UUID
    public let revision: UInt64
    public private(set) var attempted = false
    public private(set) var outcome: InsertionOutcome?
    public init(session: UUID, revision: UInt64) { self.session = session; self.revision = revision }
    public mutating func reserve(session: UUID, revision: UInt64, original: TargetToken, current: TargetToken,
                                 intent: InsertionIntent) -> InsertionDecision {
        guard !attempted else { return .alreadyAttempted }
        guard intent != .reviewOnly else { return .reviewRequired }
        guard self.session == session, self.revision == revision, original == current else { return .targetChanged }
        guard current.classification == .supportedText, current.editable, current.enabled,
              current.adapterValidated, !current.secureInput else { return .unsafeTarget }
        guard current.selection.location != NSNotFound, current.selection.location >= 0,
              current.selection.length >= 0,
              current.selection.location <= Int.max - current.selection.length else { return .unsupportedSelection }
        guard current.selection.length == 0 || intent == .replaceSelection else { return .reviewRequired }
        guard current.selectedTextWritable else { return .unsupportedCapability }
        attempted = true
        return .allowSelectedText
    }
    public mutating func finish(_ result: InsertionOutcome) {
        guard attempted, outcome == nil else { return }
        outcome = result
    }
}
