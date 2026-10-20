import XCTest
import Carbon
@testable import ClavuneCore

final class DevelopmentShortcutTests: XCTestCase {
    func testVoiceOverInteractionChordIsRejected() {
        XCTAssertFalse(DevelopmentShortcut.permits(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey)))
        XCTAssertFalse(DevelopmentShortcut.permits(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey | shiftKey)))
        XCTAssertFalse(DevelopmentShortcut.permits(keyCode: UInt32(kVK_Space), modifiers: 0))
    }
    func testOnlyExplicitDevelopmentChoicesAreAdmitted() {
        for shortcut in DevelopmentShortcut.allCases {
            XCTAssertTrue(DevelopmentShortcut.permits(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers))
        }
        XCTAssertFalse(DevelopmentShortcut.permits(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(controlKey | shiftKey)))
    }
}
