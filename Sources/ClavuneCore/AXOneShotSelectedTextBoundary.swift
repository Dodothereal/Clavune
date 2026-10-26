import AppKit
import ApplicationServices
import Carbon
import Foundation
import Security

/// Pure preflight shared by the native adapter and no-AX fixture tests. Only
/// an individually reviewed supported-text surface can be configured.
@MainActor
enum AXOneShotSurfacePolicy {
    struct Observation {
        let bundleIdentifier: String
        let role: String?
        let subrole: String?
        let fieldIdentifier: String?
        let focused: Bool?
        let enabled: Bool?
        let editable: Bool?
        let selectedTextSettable: Bool
        let secureInput: Bool
    }

    static func allows(_ observation: Observation,
                       surface: AXOneShotSelectedTextBoundary.ValidatedSurface) -> Bool {
        allowsConfiguration(surface) &&
        observation.bundleIdentifier == surface.bundleIdentifier &&
        observation.role == surface.role &&
        observation.subrole == surface.nonSecureSubrole &&
        observation.subrole != kAXSecureTextFieldSubrole &&
        observation.fieldIdentifier == surface.fieldIdentifier &&
        observation.focused == true && observation.enabled == true &&
        observation.editable == true && observation.selectedTextSettable &&
        !observation.secureInput
    }

    static func allowsConfiguration(_ surface: AXOneShotSelectedTextBoundary.ValidatedSurface) -> Bool {
        surface.acceptsResidualSelectionRace &&
        surface.validatedNotificationNames == requiredNotificationNames &&
        surface.signingTeamIdentifier.count == 10 &&
        surface.signingTeamIdentifier.utf8.allSatisfy { (65...90).contains($0) || (48...57).contains($0) } &&
        surface.approvedGuestCodeDirectorySHA1.count == 20 &&
        surface.approvedGuestCodeDirectorySHA1.contains { $0 != 0 } &&
        surface.approvedRequirementCDHash.count == 20 &&
        surface.approvedRequirementCDHash.contains { $0 != 0 } &&
        surface.bundleIdentifier.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) ||
            (48...57).contains($0) || $0 == 45 || $0 == 46 } &&
        surface.classification == .supportedText &&
        !surface.bundleIdentifier.isEmpty && !surface.fieldIdentifier.isEmpty &&
        (surface.role == kAXTextFieldRole || surface.role == kAXTextAreaRole) &&
        !surface.nonSecureSubrole.isEmpty &&
        surface.nonSecureSubrole != kAXSecureTextFieldSubrole
    }

    static let requiredNotificationNames: Set<String> = [
        kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification,
        kAXApplicationDeactivatedNotification, kAXSelectedTextChangedNotification,
        kAXValueChangedNotification, kAXUIElementDestroyedNotification
    ]

    static func validSelection(location: Int, length: Int, characterCount: Int) -> Bool {
        characterCount >= 0 && location >= 0 && length >= 0 &&
        length <= characterCount && location <= characterCount - length
    }
}

/// An unreferenced, default-disabled candidate for an explicitly approved,
/// one-shot AX SelectedText write. This is not atomic compare-and-write: another
/// process can change the selection after preflight and before AX Set. It does
/// not ask for permission, paste, or touch the clipboard. AX and workspace
/// observers revoke observed changes but cannot make delivery or Set atomic.
@MainActor
final class AXOneShotSelectedTextBoundary: ConditionalSelectedTextBoundary {
    /// A validated *surface*, not a generic text-role allowlist. No surface is
    /// supplied by the app in this source checkpoint. Future product approval
    /// must pin these identifiers after real-app security/behavioral testing.
    struct ValidatedSurface {
        let bundleIdentifier: String
        let fieldIdentifier: String
        let role: String
        let nonSecureSubrole: String
        let classification: TargetToken.Classification
        let acceptsResidualSelectionRace: Bool
        /// Must be supplied only for a separately audited exact signed build;
        /// this source checkpoint configures no real target.
        let signingTeamIdentifier: String
        let approvedGuestCodeDirectorySHA1: Data
        /// Separately pinned: modern canonical cdhash can be truncated SHA-256,
        /// whereas kSecGuestAttributeHash is documented as directory SHA-1.
        let approvedRequirementCDHash: Data
        let validatedNotificationNames: Set<String>
    }

    enum Mode {
        case disabled
        case explicitlyApproved(ValidatedSurface)
    }

    private struct Anchor {
        let pid: pid_t
        let launchDate: Date
        let window: AXUIElement
        let field: AXUIElement
        let processIdentity: UUID
        let windowIdentity: UUID
        let fieldIdentity: UUID
        let original: TargetToken
        let observation: AXOneShotNotificationLease
    }

    private let mode: Mode
    private var anchor: Anchor?
    private var captureAttempted = false
    private var writeAttempted = false
    private static let axMessageTimeoutSeconds: Float = 0.25

    init(mode: Mode = .disabled) { self.mode = mode }

    /// Captures only a narrowly validated, focused nonsecure text field. A
    /// missing AX attribute, unknown target, disabled mode or untrusted client
    /// returns nil. `nil` options never request the Accessibility prompt.
    func capture() -> TargetToken? {
        guard !captureAttempted else { return nil }
        captureAttempted = true
        closeObservation()
        guard case let .explicitlyApproved(surface) = mode,
              AXOneShotSurfacePolicy.allowsConfiguration(surface) else { return nil }
        guard AXIsProcessTrustedWithOptions(nil), !IsSecureEventInputEnabled(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == surface.bundleIdentifier,
              let launchDate = app.launchDate,
              Self.runningCodeMatches(pid: app.processIdentifier, surface: surface) else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        guard Self.setBoundedTimeout(application),
              let window = Self.element(application, kAXFocusedWindowAttribute),
              let field = Self.element(application, kAXFocusedUIElementAttribute),
              let fieldWindow = Self.element(field, kAXWindowAttribute),
              CFEqual(fieldWindow, window),
              Self.ownedBy(window, pid: app.processIdentifier),
              Self.ownedBy(field, pid: app.processIdentifier),
              Self.ownedBy(fieldWindow, pid: app.processIdentifier),
              let selection = Self.validatedSelection(field, bundleIdentifier: app.bundleIdentifier ?? "",
                                                     surface: surface) else { return nil }
        guard let observation = AXOneShotNotificationLease.start(pid: app.processIdentifier,
            application: application, window: window, field: field),
            let epoch = observation.latch.currentEpoch() else { return nil }
        let processID = UUID(), windowID = UUID(), fieldID = UUID()
        let original = TargetToken(processIdentity: processID, windowIdentity: windowID,
            fieldIdentity: fieldID, interactionGeneration: epoch, selection: selection,
            selectionRevision: epoch, classification: .supportedText, editable: true,
            enabled: true, selectedTextWritable: true, adapterValidated: true,
            secureInput: false)
        anchor = Anchor(pid: app.processIdentifier, launchDate: launchDate,
            window: window, field: field, processIdentity: processID,
            windowIdentity: windowID, fieldIdentity: fieldID, original: original,
            observation: observation)
        // Close a registration-vs-snapshot gap as far as final reads can: the
        // exact field/range/identity must still match after subscriptions arm.
        guard let fresh = checkedCurrent(), fresh.token == original else {
            closeObservation()
            return nil
        }
        return original
    }

    func currentTarget() throws -> TargetToken? {
        guard let current = checkedCurrent() else { closeObservation(); return nil }
        return current.token
    }

    func cancelObservation() { closeObservation() }

    private func closeObservation() {
        anchor?.observation.stop()
        anchor = nil
    }

    /// No await occurs between this last check and the one AX call. That only
    /// prevents *this actor* from interleaving; it cannot freeze the target app.
    /// A successful AX return proves dispatch, not verified insertion. Any
    /// error after issuing AX Set is conservatively outcome-unknown.
    func writeSelectedText(_ text: String, expecting expected: TargetToken,
                           lease: InsertionMutationLease) async throws -> InsertionOutcome {
        guard !writeAttempted else { return .outcomeUnknown }
        writeAttempted = true
        defer { closeObservation() }
        guard lease.isValid, !Task.isCancelled, !text.isEmpty,
              let anchor, anchor.original == expected,
              let current = checkedCurrent(), current.token == expected,
              lease.isValid,
              anchor.observation.latch.currentEpoch() == expected.interactionGeneration
        else { return .failedBeforeMutation }
        // This is a non-atomic cross-process check -> Set boundary. It never
        // retries even if the target changed or AX reports an error.
        let error = AXUIElementSetAttributeValue(current.field,
            kAXSelectedTextAttribute as CFString, text as CFString)
        guard error == .success else { return .outcomeUnknown }
        return lease.isValid && !Task.isCancelled &&
            anchor.observation.latch.currentEpoch() == expected.interactionGeneration
            ? .dispatchedUnverified : .outcomeUnknown
    }

    private func checkedCurrent() -> (token: TargetToken, field: AXUIElement)? {
        guard case let .explicitlyApproved(surface) = mode,
              AXOneShotSurfacePolicy.allowsConfiguration(surface),
              let anchor,
              anchor.observation.latch.currentEpoch() == anchor.original.interactionGeneration,
              AXIsProcessTrustedWithOptions(nil),
              !IsSecureEventInputEnabled(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier == anchor.pid,
              app.bundleIdentifier == surface.bundleIdentifier,
              app.launchDate == anchor.launchDate,
              Self.runningCodeMatches(pid: anchor.pid, surface: surface) else { return nil }
        let application = AXUIElementCreateApplication(anchor.pid)
        guard Self.setBoundedTimeout(application),
              let window = Self.element(application, kAXFocusedWindowAttribute),
              let field = Self.element(application, kAXFocusedUIElementAttribute),
              let fieldWindow = Self.element(field, kAXWindowAttribute),
              CFEqual(fieldWindow, window),
              Self.ownedBy(window, pid: anchor.pid),
              Self.ownedBy(field, pid: anchor.pid),
              Self.ownedBy(fieldWindow, pid: anchor.pid),
              CFEqual(window, anchor.window), CFEqual(field, anchor.field),
              let selection = Self.validatedSelection(field, bundleIdentifier: app.bundleIdentifier ?? "",
                                                     surface: surface),
              anchor.observation.latch.currentEpoch() == anchor.original.interactionGeneration
        else { return nil }
        let token = TargetToken(processIdentity: anchor.processIdentity,
            windowIdentity: anchor.windowIdentity, fieldIdentity: anchor.fieldIdentity,
            interactionGeneration: anchor.original.interactionGeneration,
            selection: selection, selectionRevision: anchor.original.selectionRevision,
            classification: .supportedText, editable: true, enabled: true,
            selectedTextWritable: true, adapterValidated: true, secureInput: false)
        return (token, field)
    }

    private static func runningCodeMatches(pid: pid_t, surface: ValidatedSurface) -> Bool {
        // The runtime target must be signed by the reviewed Team ID, have the
        // reviewed signing identifier, and match a host-supplied *guest* code
        // directory SHA-1 from the audited build. Bundle labels and an on-disk
        // path alone are insufficient identity. Unsupported PID+hash queries
        // fail closed; no disk-generated guest hash fallback is allowed.
        let hashHex = surface.approvedRequirementCDHash.map { String(format: "%02x", $0) }.joined()
        let requirementText = "anchor apple generic and identifier \"\(surface.bundleIdentifier)\" " +
            "and certificate leaf[subject.OU] = \"\(surface.signingTeamIdentifier)\" " +
            "and cdhash H\"\(hashHex)\""
        var requirement: SecRequirement?
        let defaultFlags = SecCSFlags(rawValue: 0)
        guard SecRequirementCreateWithString(requirementText as CFString,
                defaultFlags, &requirement) == errSecSuccess,
              let requirement else { return false }
        let attributes = NSDictionary(dictionary: [
            kSecGuestAttributePid as String: NSNumber(value: pid),
            kSecGuestAttributeHash as String: surface.approvedGuestCodeDirectorySHA1
        ]) as CFDictionary
        var guest: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, defaultFlags, &guest) == errSecSuccess,
              let guest,
              SecCodeCheckValidity(guest, defaultFlags, requirement) == errSecSuccess
        else { return false }
        return true
    }

    private static func validatedSelection(_ field: AXUIElement,
                                           bundleIdentifier: String,
                                           surface: ValidatedSurface) -> NSRange? {
        var settable = DarwinBoolean(false)
        let settableResult = AXUIElementIsAttributeSettable(field,
            kAXSelectedTextAttribute as CFString, &settable)
        let observation = AXOneShotSurfacePolicy.Observation(
            bundleIdentifier: bundleIdentifier,
            role: string(field, kAXRoleAttribute),
            subrole: string(field, kAXSubroleAttribute),
            fieldIdentifier: string(field, kAXIdentifierAttribute),
            focused: boolean(field, kAXFocusedAttribute),
            enabled: boolean(field, kAXEnabledAttribute),
            editable: boolean(field, kAXIsEditableAttribute),
            selectedTextSettable: settableResult == .success && settable.boolValue,
            secureInput: IsSecureEventInputEnabled())
        guard AXOneShotSurfacePolicy.allows(observation, surface: surface),
              let range = selectedRange(field) else { return nil }
        return range
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success
        else { return nil }
        return result
    }

    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let result = value(parent, attribute),
              CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        let child = result as! AXUIElement
        guard setBoundedTimeout(child) else { return nil }
        return child
    }

    private static func setBoundedTimeout(_ element: AXUIElement) -> Bool {
        // Timeouts are per AXUIElement *instance*, not all CFEqual elements.
        AXUIElementSetMessagingTimeout(element, axMessageTimeoutSeconds) == .success
    }

    private static func ownedBy(_ element: AXUIElement, pid: pid_t) -> Bool {
        var observedPID: pid_t = 0
        return AXUIElementGetPid(element, &observedPID) == .success && observedPID == pid
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    private static func boolean(_ element: AXUIElement, _ attribute: String) -> Bool? {
        guard let result = value(element, attribute),
              CFGetTypeID(result) == CFBooleanGetTypeID() else { return nil }
        return (result as? NSNumber)?.boolValue
    }

    private static func characterCount(_ element: AXUIElement) -> Int? {
        guard let result = value(element, kAXNumberOfCharactersAttribute),
              CFGetTypeID(result) == CFNumberGetTypeID(),
              let number = result as? NSNumber,
              number.int64Value >= 0,
              String(number.int64Value) == number.stringValue else { return nil }
        return Int(exactly: number.int64Value)
    }

    private static func selectedRange(_ element: AXUIElement) -> NSRange? {
        guard let result = value(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(result) == AXValueGetTypeID() else { return nil }
        let axValue = result as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range),
              let count = characterCount(element),
              AXOneShotSurfacePolicy.validSelection(location: range.location,
                  length: range.length, characterCount: count) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }
}
