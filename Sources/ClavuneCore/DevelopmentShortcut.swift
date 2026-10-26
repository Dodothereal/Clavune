import Carbon
import Foundation

/// A bounded physical-key chord, not a character or a stream of typed keys.
/// The original Space choices remain; recording also permits modified F6–F19.
/// OS/app conflicts beyond this conservative allowlist are resolved only by
/// explicit Carbon registration and must not be called conflict-free here.
public struct DevelopmentShortcut: Hashable, Identifiable, Sendable, CaseIterable {
    public let keyCode: UInt32
    public let modifiers: UInt32

    private init(uncheckedKeyCode: UInt32, modifiers: UInt32) {
        self.keyCode = uncheckedKeyCode; self.modifiers = modifiers
    }
    public init?(keyCode: UInt32, modifiers: UInt32) {
        guard Self.permits(keyCode: keyCode, modifiers: modifiers) else { return nil }
        self.init(uncheckedKeyCode: keyCode, modifiers: modifiers)
    }

    public static let controlShiftSpace = Self(uncheckedKeyCode: UInt32(kVK_Space),
        modifiers: UInt32(controlKey | shiftKey))
    public static let commandShiftSpace = Self(uncheckedKeyCode: UInt32(kVK_Space),
        modifiers: UInt32(cmdKey | shiftKey))
    /// Legacy options for compatibility; the focused recorder admits the full allowlist.
    public static let allCases: [Self] = [.controlShiftSpace, .commandShiftSpace]

    private static let functionKeys: [(UInt32, String)] = [
        (UInt32(kVK_F6), "F6"), (UInt32(kVK_F7), "F7"), (UInt32(kVK_F8), "F8"),
        (UInt32(kVK_F9), "F9"), (UInt32(kVK_F10), "F10"), (UInt32(kVK_F11), "F11"),
        (UInt32(kVK_F12), "F12"), (UInt32(kVK_F13), "F13"), (UInt32(kVK_F14), "F14"),
        (UInt32(kVK_F15), "F15"), (UInt32(kVK_F16), "F16"), (UInt32(kVK_F17), "F17"),
        (UInt32(kVK_F18), "F18"), (UInt32(kVK_F19), "F19")
    ]

    public static func permits(keyCode: UInt32, modifiers: UInt32) -> Bool {
        // Requiring an *exact* two-modifier chord excludes bare typing, the
        // Control–Option VoiceOver modifier (including extensions), and common
        // system/app letter, digit, Escape and Tab shortcuts.
        guard modifiers == UInt32(controlKey | shiftKey) ||
              modifiers == UInt32(cmdKey | shiftKey) else { return false }
        return keyCode == UInt32(kVK_Space) || functionKeys.contains { $0.0 == keyCode }
    }

    public var title: String {
        let prefix = modifiers == UInt32(controlKey | shiftKey) ? "Ctrl–Shift–" : "Cmd–Shift–"
        if keyCode == UInt32(kVK_Space) { return prefix + "Leertaste" }
        return prefix + (Self.functionKeys.first { $0.0 == keyCode }?.1 ?? "?")
    }
    /// No pressed keys, text or layout name are persisted—only a validated chord.
    public var storageValue: String { "v1:\(keyCode):\(modifiers)" }
    public var id: String { storageValue }
    public init?(storageValue: String) {
        let parts = storageValue.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "v1",
              let keyCode = UInt32(parts[1]), let modifiers = UInt32(parts[2]) else { return nil }
        self.init(keyCode: keyCode, modifiers: modifiers)
    }
}
