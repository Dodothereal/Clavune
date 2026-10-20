import AppKit
import ClavuneCore
import SwiftUI

@main
struct ClavuneApp: App {
    @StateObject private var coordinator: AppCoordinator
    private let panel: RecordingPanelController
    init() {
        do {
            let coordinator = AppCoordinator(policy: try ResourcePolicy.bundled())
            _coordinator = StateObject(wrappedValue: coordinator)
            panel = RecordingPanelController(coordinator: coordinator)
            coordinator.attachPanel(panel)
        } catch {
            // A corrupt local configuration cannot start recording.
            fatalError("Clavune resource policy unavailable")
        }
    }
    var body: some Scene {
        MenuBarExtra {
            DictationView(coordinator: coordinator)
        } label: {
            Label(coordinator.session.phase == .recording ? "REC" : ProductIdentity.displayName,
                  systemImage: AppIcon.symbol(for: coordinator.session.phase))
        }.menuBarExtraStyle(.window)
    }
}
