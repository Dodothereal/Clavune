import AppKit
import AVFoundation
import Carbon
import ClavuneCore

/// System boundaries only. Session/admission decisions stay in AppCoordinator.
/// Live resources are constructed only when the app explicitly selects .live.
@MainActor
struct CoordinatorEnvironment {
    var nowHostTime: () -> UInt64
    var secureInputEnabled: () -> Bool
    var permissionStatus: () -> AVAuthorizationStatus
    var requestPermission: () async -> Bool
    var inputDevices: () -> [AudioInputDevice]
    var chooseModel: () -> URL?
    var makeCancellation: () throws -> DecodeCancellation
    var makeWatchdog: (@escaping @MainActor () -> Void) -> (() -> Void)
    var workspaceNotifications: NotificationCenter?
    var terminate: () -> Void

    static var live: Self {
        Self(nowHostTime: { mach_absolute_time() }, secureInputEnabled: { IsSecureEventInputEnabled() },
             permissionStatus: { AVCaptureDevice.authorizationStatus(for: .audio) },
             requestPermission: { await AVCaptureDevice.requestAccess(for: .audio) },
             inputDevices: { AudioDeviceRegistry.inputs() }, chooseModel: {
                 let picker = NSOpenPanel()
                 picker.title = "Whisper-Modell bewusst importieren"
                 picker.message = "Eine geprüfte Kopie wird im Clavune-Modellordner gespeichert. Kein Audio wird übertragen. Die Qualitätsprüfung dieser Kandidaten steht noch aus."
                 picker.canChooseDirectories = false; picker.allowsMultipleSelection = false
                 return picker.runModal() == .OK ? picker.url : nil
             }, makeCancellation: { try DecodeCancellation() }, makeWatchdog: { action in
                 let timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
                     Task { @MainActor in action() }
                 }
                 return { timer.invalidate() }
             }, workspaceNotifications: NSWorkspace.shared.notificationCenter,
             terminate: { NSApp.terminate(nil) })
    }
}
