import SwiftUI

struct DictationRecoveryView: View {
    @ObservedObject var coordinator: AppCoordinator
    let recovery: DictationRecovery
    let openSettings: () -> Void
    private var ui: UILanguage { coordinator.uiLanguage }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(ui.text("Aufnahme nicht abgeschlossen"), systemImage: "exclamationmark.circle")
                .font(.title3.weight(.medium))
            Text(ui.text(recovery.guidance)).foregroundStyle(.secondary)
            HStack {
                if recovery.offersNewRecording {
                    Button(ui.text("Neu aufnehmen"), action: coordinator.retryFailedRecording)
                        .disabled(!coordinator.canRetryFailedRecording)
                }
                Button(ui.text("Einstellungen"), action: openSettings)
            }
        }.frame(maxWidth: .infinity, minHeight: 180, alignment: .leading)
    }
}
