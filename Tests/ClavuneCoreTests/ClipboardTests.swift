import AppKit
import XCTest
@testable import ClavuneCore

final class ClipboardTests: XCTestCase {
    @MainActor
    private final class RecordingSink: ClipboardWriteSink {
        enum Call: Equatable {
            case prepare(NSPasteboard.ContentsOptions)
            case write(String, NSPasteboard.PasteboardType)
        }
        var calls: [Call] = []
        var acceptsWrite = true
        func prepareForNewContents(with options: NSPasteboard.ContentsOptions) {
            calls.append(.prepare(options))
        }
        func setString(_ text: String, forType type: NSPasteboard.PasteboardType) -> Bool {
            calls.append(.write(text, type))
            return acceptsWrite
        }
    }

    func testExplicitCopyBoundaryRequestsCurrentHostOnlyAndPlainString() async {
        await MainActor.run {
            let sink = RecordingSink()
            XCTAssertTrue(LocalClipboard.copy("boundary fixture", using: sink))
            XCTAssertEqual(sink.calls, [.prepare([.currentHostOnly]), .write("boundary fixture", .string)])
        }
    }

    func testActualCopyActionRoutesSelectedUnicodeThroughHostOnlySink() async {
        await MainActor.run {
            let sink = RecordingSink()
            let editor = PlainTranscriptTextView(frame: .zero)
            editor.clipboardWriteSink = sink
            editor.isEditable = true; editor.isRichText = false
            let selected = "\u{1F469}\u{200D}\u{1F4BB} e\u{301}"
            editor.string = "prefix " + selected + " suffix"
            let range = (editor.string as NSString).range(of: selected)
            editor.setSelectedRange(range)
            let previous = editor.string
            editor.copy(nil)
            XCTAssertEqual(sink.calls, [.prepare([.currentHostOnly]), .write(selected, .string)])
            XCTAssertEqual(editor.string, previous)
            XCTAssertEqual(editor.selectedRange(), range)
        }
    }

    func testActualCutDeletesOnlySelectionAfterSuccessfulHostOnlyWrite() async {
        await MainActor.run {
            let sink = RecordingSink()
            let editor = PlainTranscriptTextView(frame: .zero)
            editor.clipboardWriteSink = sink
            editor.isEditable = true; editor.isRichText = false; editor.allowsUndo = true
            editor.string = "prefix selected suffix"
            editor.setSelectedRange((editor.string as NSString).range(of: "selected"))
            editor.cut(nil)
            XCTAssertEqual(sink.calls, [.prepare([.currentHostOnly]), .write("selected", .string)])
            XCTAssertEqual(editor.string, "prefix  suffix")
            XCTAssertEqual(editor.selectedRange(), NSRange(location: 7, length: 0))
        }
    }

    func testFailedCutWritePreservesTextAndSelection() async {
        await MainActor.run {
            let sink = RecordingSink(); sink.acceptsWrite = false
            let editor = PlainTranscriptTextView(frame: .zero)
            editor.clipboardWriteSink = sink
            editor.isEditable = true; editor.isRichText = false
            editor.string = "prefix selected suffix"
            let range = (editor.string as NSString).range(of: "selected")
            editor.setSelectedRange(range)
            editor.cut(nil)
            XCTAssertEqual(sink.calls, [.prepare([.currentHostOnly]), .write("selected", .string)])
            XCTAssertEqual(editor.string, "prefix selected suffix")
            XCTAssertEqual(editor.selectedRange(), range)
        }
    }

    func testReadonlyRawCopyWorksAndCutDoesNotWriteOrDelete() async {
        await MainActor.run {
            let sink = RecordingSink()
            let editor = PlainTranscriptTextView(frame: .zero)
            editor.clipboardWriteSink = sink
            editor.isEditable = false; editor.isSelectable = true; editor.isRichText = false
            editor.string = "raw selection"
            let range = NSRange(location: 0, length: 3)
            editor.setSelectedRange(range)
            editor.cut(nil)
            XCTAssertEqual(sink.calls, [])
            XCTAssertEqual(editor.string, "raw selection")
            XCTAssertEqual(editor.selectedRange(), range)
            editor.copy(nil)
            XCTAssertEqual(sink.calls, [.prepare([.currentHostOnly]), .write("raw", .string)])
            XCTAssertEqual(editor.string, "raw selection")
        }
    }

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
