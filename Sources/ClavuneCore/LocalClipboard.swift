import AppKit

@MainActor
public protocol ClipboardWriteSink {
    func prepareForNewContents(with options: NSPasteboard.ContentsOptions)
    func setString(_ text: String, forType type: NSPasteboard.PasteboardType) -> Bool
}

@MainActor
private struct PasteboardWriteSink: ClipboardWriteSink {
    let pasteboard: NSPasteboard
    func prepareForNewContents(with options: NSPasteboard.ContentsOptions) {
        pasteboard.prepareForNewContents(with: options)
    }
    func setString(_ text: String, forType type: NSPasteboard.PasteboardType) -> Bool {
        pasteboard.setString(text, forType: type)
    }
}

/// Explicit plain-text export shared by the Copy button and native text commands.
/// This replaces clipboard contents deliberately and never snapshots or restores them.
@MainActor
public enum LocalClipboard {
    @discardableResult
    public static func copy(_ text: String) -> Bool {
        copy(text, to: .general)
    }

    @discardableResult
    public static func copy(_ text: String, to pasteboard: NSPasteboard) -> Bool {
        copy(text, using: PasteboardWriteSink(pasteboard: pasteboard))
    }

    @discardableResult
    public static func copy(_ text: String, using sink: any ClipboardWriteSink) -> Bool {
        sink.prepareForNewContents(with: [.currentHostOnly])
        return sink.setString(text, forType: .string)
    }

    static func selectedPlainText(in text: String, ranges: [NSRange]) -> String? {
        let source = text as NSString
        var selections: [String] = []
        for range in ranges {
            guard range.location != NSNotFound, range.location >= 0,
                  range.length >= 0, range.length <= source.length,
                  range.location <= source.length - range.length else { return nil }
            if range.length > 0 { selections.append(source.substring(with: range)) }
        }
        guard !selections.isEmpty else { return nil }
        return selections.joined(separator: "\n")
    }
}

/// AppKit's selection-export hooks keep normal Copy, Cut and native selection
/// commands while routing their plain-text payload through the same clipboard policy.
@MainActor
public final class PlainTranscriptTextView: NSTextView {
    /// nil keeps the production pasteboard path. A fixture can inject a sink
    /// before invoking Copy/Cut without accessing the general clipboard.
    public var clipboardWriteSink: (any ClipboardWriteSink)?

    public override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    public override func copy(_ sender: Any?) {
        guard let text = selectedPlainText else { return }
        let sink = clipboardWriteSink ?? PasteboardWriteSink(pasteboard: .general)
        _ = LocalClipboard.copy(text, using: sink)
    }

    public override func cut(_ sender: Any?) {
        guard isEditable, let text = selectedPlainText else { return }
        let sink = clipboardWriteSink ?? PasteboardWriteSink(pasteboard: .general)
        guard LocalClipboard.copy(text, using: sink) else { return }
        // Native deletion retains selected-range editing, delegate validation and Undo.
        // A readonly raw view never writes or deletes in response to Cut.
        delete(sender)
    }

    public override func writeSelection(to pasteboard: NSPasteboard,
                                        type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string else { return false }
        return writePlainSelection(to: pasteboard)
    }

    public override func writeSelection(to pasteboard: NSPasteboard,
                                        types: [NSPasteboard.PasteboardType]) -> Bool {
        guard types.contains(.string) else { return false }
        return writePlainSelection(to: pasteboard)
    }

    private func writePlainSelection(to pasteboard: NSPasteboard) -> Bool {
        guard let text = selectedPlainText else { return false }
        let sink = clipboardWriteSink ?? PasteboardWriteSink(pasteboard: pasteboard)
        return LocalClipboard.copy(text, using: sink)
    }

    private var selectedPlainText: String? {
        LocalClipboard.selectedPlainText(in: string, ranges: selectedRanges.map(\.rangeValue))
    }
}
