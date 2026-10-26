import AppKit
import Carbon
import ClavuneCore

/// A registered chord's lifetime, without requiring Carbon in coordinator fixtures.
@MainActor
protocol HotkeyRegistration: AnyObject {
    func unregister()
}

/// Carbon registration observes only the registered chord. No event tap or text logging.
/// Per-registration event identity fences unrelated/retired Carbon deliveries.
/// Layout/device behavior still requires native QA.
@MainActor
final class HotkeyService: HotkeyRegistration {
    private static var nextEventID: UInt32 = 0
    private let eventID: EventHotKeyID
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var pressed = false
    private let action: (Bool) -> Void
    init(shortcut: DevelopmentShortcut, action: @escaping (Bool) -> Void) throws {
        guard DevelopmentShortcut.permits(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) else {
            throw DictationErrorPlaceholder.registration
        }
        Self.nextEventID = Self.nextEventID == UInt32.max ? 1 : Self.nextEventID + 1
        eventID = EventHotKeyID(signature: 0x4F575350, id: Self.nextEventID)
        self.action = action
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            let service = Unmanaged<HotkeyService>.fromOpaque(context).takeUnretainedValue()
            var incoming = EventHotKeyID(signature: 0, id: 0)
            let read = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &incoming)
            guard read == noErr, incoming.signature == service.eventID.signature,
                  incoming.id == service.eventID.id else { return OSStatus(eventNotHandledErr) }
            let down = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            MainActor.assumeIsolated { service.receive(down) }
            return noErr
        }, types.count, &types, opaque, &handler)
        guard installed == noErr else { throw DictationErrorPlaceholder.registration }
        let result = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, eventID,
                                         GetApplicationEventTarget(), 0, &reference)
        guard result == noErr else { unregister(); throw DictationErrorPlaceholder.registration }
    }
    private func receive(_ down: Bool) {
        guard pressed != down else { return }
        pressed = down; action(down)
    }
    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }; reference = nil
        if let handler { RemoveEventHandler(handler) }; handler = nil
        pressed = false
    }
    private enum DictationErrorPlaceholder: Error { case registration }
}
