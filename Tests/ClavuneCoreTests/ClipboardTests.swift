import AppKit
import XCTest
@testable import ClavuneCore

final class ClipboardTests: XCTestCase {
    func testExplicitCopyReplacesOnlyAnIsolatedNamedPasteboardWithExactPlainText() async {
        await MainActor.run {
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            board.setString("prior fixture contents", forType: .string)
            let text = "Nicht fünfzehn, sondern fünfzig. SwiftUI — 3.1.0"
            XCTAssertTrue(LocalClipboard.copy(text, to: board))
            XCTAssertEqual(board.string(forType: .string), text)
            XCTAssertFalse(board.types?.contains(.rtf) ?? true)
        }
    }

    func testNativeReadonlyAndEditableSelectionExportPreservesUnicode() async {
        await MainActor.run {
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            let text = "A \u{1F469}\u{200D}\u{1F4BB} e\u{301} Z"
            let selected = "\u{1F469}\u{200D}\u{1F4BB} e\u{301}"
            for editable in [false, true] {
                let editor = PlainTranscriptTextView(frame: .zero)
                editor.isRichText = false; editor.isEditable = editable; editor.isSelectable = true
                editor.string = text
                editor.setSelectedRange((text as NSString).range(of: selected))
                XCTAssertTrue(editor.writeSelection(to: board, types: editor.writablePasteboardTypes))
                XCTAssertEqual(board.string(forType: .string), selected)
                XCTAssertFalse(board.types?.contains(.rtf) ?? true)
            }
        }
    }

    func testEmptySelectionLeavesNamedPasteboardUntouched() async {
        await MainActor.run {
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            LocalClipboard.copy("keep fixture", to: board)
            let priorChange = board.changeCount
            let editor = PlainTranscriptTextView(frame: .zero)
            editor.string = "fixture"; editor.setSelectedRange(NSRange(location: 3, length: 0))
            XCTAssertFalse(editor.writeSelection(to: board, types: [.string]))
            XCTAssertEqual(board.changeCount, priorChange)
            XCTAssertEqual(board.string(forType: .string), "keep fixture")
        }
    }
}
