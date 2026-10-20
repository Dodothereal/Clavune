import AppKit
import ClavuneCore
import SwiftUI

enum AppIcon {
    static func symbol(for phase: SessionPhase) -> String {
        switch phase {
        case .recording: return "mic.fill"
        case .preparing, .stopping, .transcribing: return "waveform"
        case .failed: return "exclamationmark.circle"
        case .review: return "text.bubble"
        default: return "mic"
        }
    }
}

struct DictationView: View {
    @ObservedObject var coordinator: AppCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(ProductIdentity.displayName, systemImage: AppIcon.symbol(for: coordinator.session.phase))
                .font(.headline)
            Text(coordinator.message).font(.callout).accessibilityAddTraits(.updatesFrequently)
            if coordinator.session.phase == .recording || coordinator.session.phase == .stopping {
                Text(String(format: "%.1f / %d s — Kanal %d", coordinator.elapsed,
                            coordinator.policy.sessionLimitSeconds, coordinator.channel + 1))
                    .monospacedDigit()
                ProgressView(value: Double(coordinator.level), total: 1).accessibilityLabel("Mikrofonpegel")
            }
            HStack {
                Button("Aufnehmen", action: coordinator.start).disabled(!coordinator.canStart)
                Button("Stoppen", action: coordinator.stop)
                    .disabled(![.recording, .preparing].contains(coordinator.session.phase))
                Button("Abbrechen", action: coordinator.cancel).disabled(!coordinator.busy)
            }
            if coordinator.session.phase == .review {
                TranscriptEditor(text: $coordinator.editedText).frame(minHeight: 130)
                    .accessibilityLabel("Bearbeitbare Transkriptvorschau")
                DisclosureGroup("Unveränderte Erkennungsausgabe") {
                    ScrollView { Text(coordinator.session.rawTranscript).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 100)
                }
                HStack {
                    Button("Kopieren", action: coordinator.copy).disabled(coordinator.editedText.isEmpty)
                    Button("Verwerfen", action: coordinator.discard)
                }
                Text("Die Vorschau bleibt nur im Arbeitsspeicher. Kopieren ersetzt bewusst die Zwischenablage.").font(.caption)
            }
            Divider()
            DisclosureGroup("Einstellungen und Modell") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(coordinator.modelStatus).font(.caption).textSelection(.enabled)
                    HStack {
                        Button("Modell importieren …", action: coordinator.importModel)
                        Button("Modell entladen", action: coordinator.unload)
                    }.disabled(coordinator.busy)
                    Picker("Sprache", selection: $coordinator.language) {
                        ForEach(LanguageMode.allCases) { Text($0.title).tag($0) }
                    }.disabled(coordinator.busy)
                    Picker("Mikrofon", selection: $coordinator.deviceUID) {
                        Text("Systemstandard").tag("")
                        ForEach(coordinator.devices) { Text($0.name).tag($0.uid) }
                    }.disabled(coordinator.busy)
                    Stepper("Eingangskanal: \(coordinator.channel + 1)", value: $coordinator.channel, in: 0...31)
                        .disabled(coordinator.busy)
                    Button("Geräte aktualisieren", action: coordinator.refreshDevices).disabled(coordinator.busy)
                    Toggle("Globalen Hotkey aktivieren (Entwicklung)", isOn: $coordinator.hotkeyEnabled)
                        .onChange(of: coordinator.hotkeyEnabled) { coordinator.configureHotkey() }
                        .disabled(coordinator.busy)
                    Toggle("Halten zum Sprechen", isOn: $coordinator.holdToTalk).disabled(coordinator.busy)
                    Text(coordinator.hotkeyStatus).font(.caption)
                    Text("Sitzungslimit: \(coordinator.policy.sessionLimitSeconds) s. Bei Verlust oder Limit wird die Aufnahme sichtbar beendet. Keine Cloud-Inferenz, kein automatischer Verlauf. Qualitäts- und Gerätetests stehen noch aus.")
                        .font(.caption)
                }.padding(.top, 4)
            }
            if let metrics = coordinator.metrics {
                DisclosureGroup("Lokale Messpunkte") {
                    VStack(alignment: .leading) {
                        Text("PCM: \(metrics.frames16k) Samples")
                        if let seconds = metrics.modelLoadSeconds { Text(String(format: "Modellladen: %.3f s (%@)", seconds, metrics.modelWarm ? "warm" : "kalt")) }
                        if let seconds = metrics.decodeSeconds { Text(String(format: "Batch-Aufruf: %.3f s", seconds)) }
                        Text("Einfügen, Energie, Gesamtspeicher und Qualitätsvergleich: ungemessen")
                    }.font(.caption)
                }
            }
            HStack {
                Text("Entwicklungsbuild — keine Release-Freigabe").font(.caption)
                Spacer()
                Button("Beenden", action: coordinator.quit)
            }
        }
        .padding()
        .frame(width: 440)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: coordinator.session.phase)
    }
}

struct TranscriptEditor: NSViewRepresentable {
    @Binding var text: String
    func makeCoordinator() -> Delegate { Delegate(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let editor = scroll.documentView as? NSTextView else { return scroll }
        editor.isRichText = false; editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticTextCompletionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        editor.delegate = context.coordinator
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.parent = self
        if let editor = view.documentView as? NSTextView, editor.string != text {
            editor.string = text
        }
    }
    final class Delegate: NSObject, NSTextViewDelegate {
        var parent: TranscriptEditor
        init(_ parent: TranscriptEditor) { self.parent = parent }
        func textDidChange(_ note: Notification) {
            if let editor = note.object as? NSTextView { parent.text = editor.string }
        }
    }
}

@MainActor
final class RecordingPanelController {
    private let panel: NSPanel
    init(coordinator: AppCoordinator) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
                        styleMask: [.titled, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)
        panel.title = ProductIdentity.displayName + " — Aufnahme und Vorschau"
        panel.level = .floating; panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: DictationView(coordinator: coordinator))
        panel.center()
    }
    func show() { panel.orderFrontRegardless() }
    func hide() { panel.orderOut(nil) }
}
