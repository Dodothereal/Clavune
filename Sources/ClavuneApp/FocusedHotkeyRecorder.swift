import AppKit
import Carbon
import SwiftUI

/// Pure key-edge staging. Registration must never occur while the captured
/// physical key is still down; duplicates and unrelated releases do nothing.
struct HotkeyChordCaptureState {
    private var heldKeys: Set<UInt32> = []
    private var candidate: (keyCode: UInt32, modifiers: UInt32)?
    var hasPending: Bool { !heldKeys.isEmpty }
    mutating func keyDown(keyCode: UInt32, modifiers: UInt32, repeatEvent: Bool) {
        guard !repeatEvent else { return }
        guard heldKeys.insert(keyCode).inserted else { return }
        // Overlapping physical keys poison this attempt; retain every held
        // code until its matching release so Cancel cannot rearm underneath it.
        if heldKeys.count == 1 { candidate = (keyCode, modifiers) }
        else { candidate = nil }
    }
    mutating func modifiersChanged(_ modifiers: UInt32) {
        if hasPending, let candidate, candidate.modifiers != modifiers { self.candidate = nil }
    }
    mutating func keyUp(keyCode: UInt32, modifiers: UInt32) -> (keyCode: UInt32, modifiers: UInt32)? {
        guard heldKeys.remove(keyCode) != nil else { return nil }
        defer { self.candidate = nil }
        guard heldKeys.isEmpty, let candidate, candidate.keyCode == keyCode,
              candidate.modifiers == modifiers else { return nil }
        return candidate
    }
    mutating func clear() { heldKeys.removeAll(); candidate = nil }
}

/// Focused, local-only chord entry. It never installs an event tap or global
/// monitor, reads key characters, or changes the system shortcut registry.
@MainActor
struct FocusedHotkeyRecorder: NSViewRepresentable {
    let accessibilityTitle: String
    let onChord: (UInt32, UInt32) -> Void
    let onCancel: () -> Void
    let onPendingChange: (Bool) -> Void
    let onFocusLost: (Bool) -> Void

    func makeNSView(context: Context) -> KeyCaptureView {
        let view = KeyCaptureView()
        view.label = accessibilityTitle
        view.onChord = onChord
        view.onCancel = onCancel
        view.onPendingChange = onPendingChange
        view.onFocusLost = onFocusLost
        return view
    }

    func updateNSView(_ view: KeyCaptureView, context: Context) {
        view.label = accessibilityTitle
        view.onChord = onChord
        view.onCancel = onCancel
        view.onPendingChange = onPendingChange
        view.onFocusLost = onFocusLost
    }

    static func dismantleNSView(_ view: KeyCaptureView, coordinator: ()) {
        view.onChord = nil
        view.onCancel = nil
        view.onPendingChange = nil
        view.onFocusLost = nil
        view.capture.clear()
        if let window = view.window, window.firstResponder === view {
            _ = window.makeFirstResponder(nil)
        }
    }

    final class KeyCaptureView: NSView {
        var label = "" { didSet { needsDisplay = true } }
        var onChord: ((UInt32, UInt32) -> Void)?
        var onCancel: (() -> Void)?
        var onPendingChange: ((Bool) -> Void)?
        var onFocusLost: ((Bool) -> Void)?
        var capture = HotkeyChordCaptureState()
        private var initialFocusRequested = false

        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, !initialFocusRequested else { return }
            initialFocusRequested = true
            // Focus only when attached to the host that began recording.
            // A later status publication must not steal focus back.
            Task { @MainActor [weak self] in
                guard let self, let window = self.window else { return }
                _ = window.makeFirstResponder(self)
            }
        }
        override func becomeFirstResponder() -> Bool {
            needsDisplay = true
            return true
        }
        override func resignFirstResponder() -> Bool {
            let hadPending = capture.hasPending
            capture.clear()
            needsDisplay = true
            onFocusLost?(hadPending)
            onPendingChange?(false)
            return true
        }
        override func mouseDown(with event: NSEvent) {
            _ = window?.makeFirstResponder(self)
        }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == UInt16(kVK_Escape) {
                let hadPending = capture.hasPending
                capture.clear()
                if hadPending { onFocusLost?(true) } else { onCancel?() }
                onPendingChange?(false)
                return
            }
            capture.keyDown(keyCode: UInt32(event.keyCode), modifiers: Self.carbonModifiers(event),
                            repeatEvent: event.isARepeat)
            onPendingChange?(capture.hasPending)
        }
        override func flagsChanged(with event: NSEvent) {
            capture.modifiersChanged(Self.carbonModifiers(event))
            onPendingChange?(capture.hasPending)
        }
        override func keyUp(with event: NSEvent) {
            let chord = capture.keyUp(keyCode: UInt32(event.keyCode), modifiers: Self.carbonModifiers(event))
            onPendingChange?(capture.hasPending)
            guard let chord else { return }
            onChord?(chord.keyCode, chord.modifiers)
        }
        private static func carbonModifiers(_ event: NSEvent) -> UInt32 {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            var modifiers: UInt32 = 0
            if flags.contains(.control) { modifiers |= UInt32(controlKey) }
            if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
            if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
            if flags.contains(.option) { modifiers |= UInt32(optionKey) }
            return modifiers
        }
        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            let bounds = self.bounds.insetBy(dx: 1, dy: 1)
            let outline = NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5)
            NSColor.controlBackgroundColor.setFill(); outline.fill()
            (window?.firstResponder === self ? NSColor.keyboardFocusIndicatorColor : NSColor.separatorColor).setStroke()
            outline.stroke()
            (label as NSString).draw(in: bounds.insetBy(dx: 8, dy: 5), withAttributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.labelColor
            ])
        }
        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .group }
        override func accessibilityLabel() -> String? { label }
    }
}
