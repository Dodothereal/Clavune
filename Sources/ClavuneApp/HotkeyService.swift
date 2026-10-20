import AppKit
import Carbon

/// Carbon registration observes only the registered chord. No event tap or text logging.
/// Fixed development chord; configurable recorder and layout/device QA remain an M2 gate.
@MainActor
final class HotkeyService {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var pressed = false
    private let action: (Bool) -> Void
    init(action: @escaping (Bool) -> Void) throws {
        self.action = action
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            let service = Unmanaged<HotkeyService>.fromOpaque(context).takeUnretainedValue()
            let down = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            MainActor.assumeIsolated { service.receive(down) }
            return noErr
        }, types.count, &types, opaque, &handler)
        guard installed == noErr else { throw DictationErrorPlaceholder.registration }
        let id = EventHotKeyID(signature: 0x4F575350, id: 1)
        let result = RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), id,
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
