import AppKit

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
        pasteboard.prepareForNewContents(with: [.currentHostOnly])
        return pasteboard.setString(text, forType: .string)
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
    public override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

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
        let ranges = selectedRanges.map(\.rangeValue)
        guard let text = LocalClipboard.selectedPlainText(in: string, ranges: ranges) else { return false }
        return LocalClipboard.copy(text, to: pasteboard)
    }
}
