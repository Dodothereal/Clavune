import AppKit
import ClavuneCore
import SwiftUI

@main
struct ClavuneApp: App {
    @NSApplicationDelegateAdaptor(DesktopApplicationDelegate.self) private var appDelegate
    // Retain the legacy ObservableObject without subscribing the entire App scene
    // to its publications. Content views explicitly observe it where needed.
    @State private var coordinator: AppCoordinator
    @StateObject private var scenePresentation: ScenePresentationState
    // Private comparison builds can render the existing main view at the
    // auxiliary-panel dimensions without touching a production window size.
    private var qaCompactWindow: Bool {
        coordinator.launchConfiguration.isQA &&
            ProcessInfo.processInfo.environment["CLAVUNE_QA_COMPACT_WINDOW"] == "1"
    }
    init() {
        do {
            let coordinator = try AppCoordinator(policy: ResourcePolicy.bundled(),
                launchConfiguration: AppLaunchConfiguration.parse(environment: ProcessInfo.processInfo.environment))
            _coordinator = State(initialValue: coordinator)
            _scenePresentation = StateObject(wrappedValue: coordinator.scenePresentation)
            let panel = RecordingPanelController(coordinator: coordinator)
            coordinator.attachPanel(panel)
        } catch {
            fatalError("Clavune launch configuration or resource policy unavailable")
        }
    }
    var body: some Scene {
        Window(ProductIdentity.displayName, id: "main") {
            DictationView(coordinator: coordinator,
                          statisticsPreviewInQA: coordinator.launchConfiguration.isQA)
                .frame(minWidth: 560,
                       minHeight: coordinator.launchConfiguration.isQA ? QAWindowLayout.emptyStatisticsHeight : 520)
                .background(DesktopWindowRegistration(delegate: appDelegate))
                .onAppear { appDelegate.coordinator = coordinator }
        }
        .defaultSize(width: qaCompactWindow ? 560 : 780,
                     height: coordinator.launchConfiguration.isQA ? QAWindowLayout.compactHeight : 680)
        // Use macOS's standard Quit command. The application delegate below
        // still defers termination until the coordinator has drained its work.
        MenuBarExtra(isInserted: Binding(
            get: { scenePresentation.menuBarEnabled },
            set: { coordinator.menuBarEnabled = $0 })) {
            MenuBarControls(coordinator: coordinator)
        } label: {
            MenuBarStatusLabel(coordinator: coordinator)
        }
    }
}

private struct MenuBarStatusLabel: View {
    @ObservedObject var coordinator: AppCoordinator
    var body: some View {
        Label(ProductIdentity.displayName,
              systemImage: AppIcon.symbol(for: coordinator.session.phase, microphone: coordinator.microphone.state))
    }
}

private struct MenuBarControls: View {
    @ObservedObject var coordinator: AppCoordinator
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button(coordinator.uiLanguage.text("Clavune öffnen")) {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Text(coordinator.uiLanguage.text(coordinator.message))
        Divider()
        Button(coordinator.uiLanguage.text("Aufnehmen"), action: coordinator.start).disabled(!coordinator.canStart)
        Button(coordinator.uiLanguage.text("Stoppen"), action: coordinator.stop)
            .disabled(!coordinator.canStop)
        Button(coordinator.uiLanguage.text("Abbrechen"), action: coordinator.cancel).disabled(!coordinator.busy)
        Divider()
        Button(coordinator.uiLanguage.text("Beenden"), action: coordinator.quit)
    }
}

@MainActor
final class DesktopApplicationDelegate: NSObject, NSApplicationDelegate {
    var mainWindow: NSWindow?
    weak var coordinator: AppCoordinator?
    var bringMainWindowToFront: @MainActor (NSWindow) -> Void = { $0.makeKeyAndOrderFront(nil) }
    var activateApplication: @MainActor (NSApplication) -> Void = {
        $0.activate(ignoringOtherApps: true)
    }
    private var closeObserver: NSObjectProtocol?
    private var keyObserver: NSObjectProtocol?
    func register(_ window: NSWindow) {
        if mainWindow === window { return }
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        mainWindow = window
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("clavune.main")
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
            object: window, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.mainWindow?.isVisible != true else { return }
                    self.coordinator?.revealPanelIfBusy()
                }
            }
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
            object: window, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.handoffToMainWindow() }
            }
    }
    func handoffToMainWindow() {
        coordinator?.handoffPanelToMainWindow(isVisible:
            mainWindow?.isVisible == true && mainWindow?.isMiniaturized == false)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let mainWindow { bringMainWindowToFront(mainWindow) }
        handoffToMainWindow()
        activateApplication(sender)
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // The coordinator's termination callback re-enters only after its drain.
        guard let coordinator, !coordinator.terminationReady else { return .terminateNow }
        coordinator.quit()
        return .terminateCancel
    }
}

private struct DesktopWindowRegistration: NSViewRepresentable {
    let delegate: DesktopApplicationDelegate
    func makeNSView(context: Context) -> RegistrationView { RegistrationView(delegate: delegate) }
    func updateNSView(_ nsView: RegistrationView, context: Context) {}
    final class RegistrationView: NSView {
        let owner: DesktopApplicationDelegate
        init(delegate: DesktopApplicationDelegate) { owner = delegate; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { owner.register(window) }
        }
    }
}
