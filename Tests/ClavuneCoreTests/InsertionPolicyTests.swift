import XCTest
@testable import ClavuneCore

final class InsertionPolicyTests: XCTestCase {
    private func target(selection: NSRange = NSRange(location: 4, length: 0),
                        classification: TargetToken.Classification = .supportedText,
                        writable: Bool = true, secure: Bool = false) -> TargetToken {
        TargetToken(processIdentity: UUID(), windowIdentity: UUID(), fieldIdentity: UUID(),
                    interactionGeneration: 0, selection: selection, selectionRevision: 0,
                    classification: classification, editable: true, enabled: true,
                    selectedTextWritable: writable, adapterValidated: true, secureInput: secure)
    }
    func testPreviewIsDefaultAndNonemptySelectionRequiresExplicitReplacement() {
        let id = UUID(), selected = target(selection: NSRange(location: 2, length: 5))
        var fence = InsertionFence(session: id, revision: 1)
        XCTAssertEqual(fence.reserve(session: id, revision: 1, original: selected, current: selected, intent: .reviewOnly), .reviewRequired)
        XCTAssertEqual(fence.reserve(session: id, revision: 1, original: selected, current: selected, intent: .insertAtCaret), .reviewRequired)
        XCTAssertFalse(fence.attempted)
        XCTAssertEqual(fence.reserve(session: id, revision: 1, original: selected, current: selected, intent: .replaceSelection), .allowSelectedText)
    }
    func testUnknownWriteOutcomeNeverPermitsRetryOrFallback() {
        let id = UUID(), token = target()
        var fence = InsertionFence(session: id, revision: 1)
        XCTAssertEqual(fence.reserve(session: id, revision: 1, original: token, current: token, intent: .insertAtCaret), .allowSelectedText)
        fence.finish(.outcomeUnknown)
        XCTAssertEqual(fence.reserve(session: id, revision: 1, original: token, current: token, intent: .insertAtCaret), .alreadyAttempted)
    }
    func testFocusAndTranscriptRevisionChangesBlockMutation() {
        let id = UUID(), old = target(), changed = target()
        var fence = InsertionFence(session: id, revision: 2)
        XCTAssertEqual(fence.reserve(session: id, revision: 2, original: old, current: changed, intent: .insertAtCaret), .targetChanged)
        XCTAssertEqual(fence.reserve(session: id, revision: 1, original: old, current: old, intent: .insertAtCaret), .targetChanged)
        XCTAssertFalse(fence.attempted)
    }
    func testSecureUnknownAndTerminalTargetsAreBlockedWithoutClipboardEscape() {
        for token in [target(classification: .secure), target(classification: .terminal),
                      target(classification: .unknown), target(secure: true)] {
            let id = UUID(); var fence = InsertionFence(session: id, revision: 1)
            XCTAssertEqual(fence.reserve(session: id, revision: 1, original: token, current: token, intent: .insertAtCaret), .unsafeTarget)
            XCTAssertFalse(fence.attempted)
        }
    }
    func testSelectedTextCapabilityIsRequiredPerElement() {
        let id = UUID(), token = target(writable: false)
        var fence = InsertionFence(session: id, revision: 1)
        XCTAssertEqual(fence.reserve(session: id, revision: 1, original: token, current: token, intent: .insertAtCaret), .unsupportedCapability)
        XCTAssertFalse(fence.attempted)
    }
}
