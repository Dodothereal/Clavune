import ApplicationServices
import Foundation
import XCTest
@testable import ClavuneCore

/// Pure metadata checks only. These tests never call AX, ask for permission,
/// inspect a real target, or write SelectedText.
final class AXOneShotSurfacePolicyTests: XCTestCase {
    @MainActor private func surface(
        classification: TargetToken.Classification = .supportedText,
        role: String = kAXTextAreaRole,
        subrole: String = "AXValidatedPlainTextArea",
        acceptsRace: Bool = true,
        teamID: String = "ABCDE12345",
        hash: Data = Data(repeating: 0xA5, count: 20),
        requirementHash: Data = Data(repeating: 0xB6, count: 20),
        notifications: Set<String>? = nil
    ) -> AXOneShotSelectedTextBoundary.ValidatedSurface {
        .init(bundleIdentifier: "org.example.synthetic-target", fieldIdentifier: "reviewed-entry",
              role: role, nonSecureSubrole: subrole, classification: classification,
              acceptsResidualSelectionRace: acceptsRace,
              signingTeamIdentifier: teamID, approvedGuestCodeDirectorySHA1: hash,
              approvedRequirementCDHash: requirementHash,
              validatedNotificationNames: notifications ?? AXOneShotSurfacePolicy.requiredNotificationNames)
    }

    @MainActor private func observation(
        bundle: String = "org.example.synthetic-target",
        role: String? = kAXTextAreaRole,
        subrole: String? = "AXValidatedPlainTextArea",
        identifier: String? = "reviewed-entry",
        focused: Bool? = true, enabled: Bool? = true, editable: Bool? = true,
        settable: Bool = true, secureInput: Bool = false
    ) -> AXOneShotSurfacePolicy.Observation {
        .init(bundleIdentifier: bundle, role: role, subrole: subrole,
              fieldIdentifier: identifier, focused: focused, enabled: enabled,
              editable: editable, selectedTextSettable: settable, secureInput: secureInput)
    }

    @MainActor func testOnlyExactValidatedNonsecureFocusedEditableSurfacePasses() {
        XCTAssertTrue(AXOneShotSurfacePolicy.allows(observation(), surface: surface()))
        XCTAssertFalse(AXOneShotSurfacePolicy.allows(
            observation(bundle: "org.example.other"), surface: surface()))
        XCTAssertFalse(AXOneShotSurfacePolicy.allows(
            observation(identifier: "terminal-pane"), surface: surface()))
        XCTAssertFalse(AXOneShotSurfacePolicy.allows(
            observation(subrole: nil), surface: surface()))
        XCTAssertFalse(AXOneShotSurfacePolicy.allows(
            observation(subrole: kAXSecureTextFieldSubrole), surface: surface()))
        XCTAssertFalse(AXOneShotSurfacePolicy.allows(
            observation(secureInput: true), surface: surface()))
    }

    @MainActor func testMissingCapabilityAndUnknownMetadataFailClosed() {
        let approved = surface()
        for observed in [observation(role: nil), observation(identifier: nil),
                         observation(focused: nil), observation(focused: false),
                         observation(enabled: nil), observation(enabled: false),
                         observation(editable: nil), observation(editable: false),
                         observation(settable: false)] {
            XCTAssertFalse(AXOneShotSurfacePolicy.allows(observed, surface: approved))
        }
    }

    @MainActor func testSecureUnknownTerminalAndUnapprovedRiskNeverConfigure() {
        for classification in [TargetToken.Classification.secure, .unknown, .terminal] {
            XCTAssertFalse(AXOneShotSurfacePolicy.allowsConfiguration(
                surface(classification: classification)))
        }
        XCTAssertFalse(AXOneShotSurfacePolicy.allowsConfiguration(
            surface(subrole: kAXSecureTextFieldSubrole)))
        XCTAssertFalse(AXOneShotSurfacePolicy.allowsConfiguration(
            surface(acceptsRace: false)))
        XCTAssertFalse(AXOneShotSurfacePolicy.allowsConfiguration(
            surface(role: "AXUnknownRole")))
    }

    @MainActor func testSignedBuildPinShapesAndDeclaredNotificationSetRequired() {
        XCTAssertFalse(AXOneShotSurfacePolicy.allowsConfiguration(surface(teamID: "")))
        XCTAssertFalse(AXOneShotSurfacePolicy.allowsConfiguration(surface(teamID: "123")))
        XCTAssertFalse(AXOneShotSurfacePolicy.allowsConfiguration(
            surface(hash: Data(repeating: 0, count: 20))))
        XCTAssertFalse(AXOneShotSurfacePolicy.allowsConfiguration(
            surface(hash: Data(repeating: 0xA5, count: 8))))
        XCTAssertFalse(AXOneShotSurfacePolicy.allowsConfiguration(
            surface(requirementHash: Data(repeating: 0, count: 20))))
        XCTAssertFalse(AXOneShotSurfacePolicy.allowsConfiguration(
            surface(requirementHash: Data(repeating: 0xB6, count: 8))))
        var incomplete = AXOneShotSurfacePolicy.requiredNotificationNames
        incomplete.remove(kAXValueChangedNotification)
        XCTAssertFalse(AXOneShotSurfacePolicy.allowsConfiguration(
            surface(notifications: incomplete)))
        XCTAssertFalse(AXOneShotSurfacePolicy.allowsConfiguration(
            surface(notifications: [])))
    }

    @MainActor func testSelectionMustFitFreshCharacterCountIncludingEndCaret() {
        XCTAssertTrue(AXOneShotSurfacePolicy.validSelection(
            location: 5, length: 0, characterCount: 5))
        XCTAssertTrue(AXOneShotSurfacePolicy.validSelection(
            location: 2, length: 3, characterCount: 5))
        XCTAssertFalse(AXOneShotSurfacePolicy.validSelection(
            location: 6, length: 0, characterCount: 5))
        XCTAssertFalse(AXOneShotSurfacePolicy.validSelection(
            location: 2, length: 4, characterCount: 5))
        XCTAssertFalse(AXOneShotSurfacePolicy.validSelection(
            location: -1, length: 0, characterCount: 5))
        XCTAssertFalse(AXOneShotSurfacePolicy.validSelection(
            location: Int.max, length: Int.max, characterCount: Int.max))
    }
}
