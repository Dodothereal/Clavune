import Carbon

/// Provisional choices until the full shortcut recorder and accessibility QA are complete.
public enum DevelopmentShortcut: String, CaseIterable, Identifiable, Sendable {
    case controlShiftSpace, commandShiftSpace
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .controlShiftSpace: return "Ctrl–Shift–Leertaste"
        case .commandShiftSpace: return "Cmd–Shift–Leertaste"
        }
    }
    public var keyCode: UInt32 { UInt32(kVK_Space) }
    public var modifiers: UInt32 {
        switch self {
        case .controlShiftSpace: return UInt32(controlKey | shiftKey)
        case .commandShiftSpace: return UInt32(cmdKey | shiftKey)
        }
    }
    public static func permits(keyCode: UInt32, modifiers: UInt32) -> Bool {
        // Ctrl–Option is the VoiceOver modifier. Do not take its interaction chord.
        let voiceOver = UInt32(controlKey | optionKey)
        guard keyCode == UInt32(kVK_Space), modifiers & voiceOver != voiceOver else { return false }
        return allCases.contains { $0.keyCode == keyCode && $0.modifiers == modifiers }
    }
}
