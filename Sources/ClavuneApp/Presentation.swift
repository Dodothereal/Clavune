import AppKit
import ClavuneCore
import SwiftUI

private struct ObservatoryTranscriptCornerFrame: Shape {
    func path(in rect: CGRect) -> Path {
        let inset: CGFloat = 1
        let length = min(14, min(rect.width, rect.height) * 0.22)
        let left = rect.minX + inset, right = rect.maxX - inset
        let top = rect.minY + inset, bottom = rect.maxY - inset
        var path = Path()
        path.move(to: CGPoint(x: left + length, y: top)); path.addLine(to: CGPoint(x: left, y: top))
        path.addLine(to: CGPoint(x: left, y: top + length))
        path.move(to: CGPoint(x: right - length, y: top)); path.addLine(to: CGPoint(x: right, y: top))
        path.addLine(to: CGPoint(x: right, y: top + length))
        path.move(to: CGPoint(x: left, y: bottom - length)); path.addLine(to: CGPoint(x: left, y: bottom))
        path.addLine(to: CGPoint(x: left + length, y: bottom))
        path.move(to: CGPoint(x: right, y: bottom - length)); path.addLine(to: CGPoint(x: right, y: bottom))
        path.addLine(to: CGPoint(x: right - length, y: bottom))
        return path
    }
}

enum AppIcon {
    static func symbol(for phase: SessionPhase, microphone: MicrophoneLifecycle.State) -> String {
        if microphone != .closed { return "mic.fill" }
        switch phase {
        case .recording: return "mic.fill"
        case .preparing, .stopping, .transcribing: return "waveform"
        case .failed: return "exclamationmark.circle"
        case .review: return "text.bubble"
        default: return "mic"
        }
    }
}

enum DictationGuidanceMode: Equatable {
    case hidden
    case recovery
    case audioImportFailure
    case audioImportCancelled
    case selectedModelUnavailable
    case ready
}

struct DictationView: View {
    @ObservedObject var coordinator: AppCoordinator
    var isAuxiliaryPanel = false
    @State private var settingsVisible = false
    @State private var statisticsVisible = false
    @State private var ownsHotkeyRecording = false
    @State private var qaPreferredWidth: CGFloat?
    @State private var qaCaptureInFlight = false
    @State private var qaCaptureOutcome: String?
    @StateObject private var statistics: LocalStatisticsPageModel
    let statisticsPreviewInQA: Bool
    @MainActor init(coordinator: AppCoordinator, isAuxiliaryPanel: Bool = false,
                    statisticsPreviewInQA: Bool = false,
                    statisticsLoader: @escaping LocalStatisticsPageModel.Loader = {
                        try await LocalStatisticsDiskLoader.load($0)
                    }, statisticsPreviewModel: LocalStatisticsPageModel? = nil) {
        self.coordinator = coordinator
        self.isAuxiliaryPanel = isAuxiliaryPanel
        let preview = statisticsPreviewInQA && coordinator.launchConfiguration.isQA
        self.statisticsPreviewInQA = preview
        let pageModel: LocalStatisticsPageModel
        if preview {
            pageModel = statisticsPreviewModel ?? LocalStatisticsPageModel(
                loader: { period in try await LocalStatisticsSyntheticPreview.load(period) },
                now: { LocalStatisticsSyntheticPreview.referenceTime })
        } else {
            pageModel = LocalStatisticsPageModel(loader: statisticsLoader)
        }
        _statistics = StateObject(wrappedValue: pageModel)
    }
    private var ui: UILanguage { coordinator.uiLanguage }
    private var qaReviewBytes: Int {
        guard coordinator.launchConfiguration.isQA else { return 0 }
        return max(coordinator.session.rawTranscript.utf8.count, coordinator.editedText.utf8.count)
    }
    private var reviewWordCount: Int { LocalMetricsEvent.wordCount(coordinator.editedText) }
    private var reviewStatusStrip: some View {
        HStack(spacing: 8) {
            Text("\(reviewWordCount) \(ui.text("Wörter"))")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .tracking(0.3)
                .foregroundStyle(ObservatoryAppearance.muted)
            Spacer(minLength: 8)
            if coordinator.hasUnsavedReview {
                HStack(spacing: 6) {
                    Circle()
                        .fill(ObservatoryAppearance.warning)
                        .frame(width: 5, height: 5)
                        .accessibilityHidden(true)
                    Text(ui.text("Ungespeichert"))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .tracking(0.5)
                        .foregroundStyle(ObservatoryAppearance.warning)
                }
            }
        }
        .frame(minHeight: 18)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("clavune.review.metadata")
    }
    private var qaWindowHeight: CGFloat? {
        QAWindowLayout.contentHeight(isQA: coordinator.launchConfiguration.isQA,
            isAuxiliaryPanel: isAuxiliaryPanel, settingsVisible: settingsVisible,
            statisticsVisible: statisticsVisible, statisticsPreview: statisticsPreviewInQA,
            statisticsPreviewHasOneSource: statisticsPreviewInQA &&
                statistics.selectedPeriod == .last24Hours,
            phase: coordinator.session.phase,
            busy: coordinator.busy, reviewUTF8Bytes: qaReviewBytes)
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var guidanceMode: DictationGuidanceMode {
        if coordinator.session.phase == .review || coordinator.busy { return .hidden }
        if coordinator.dictationRecovery != nil { return .recovery }
        // A selected model that is no longer valid blocks both recording and
        // audio-file retry, regardless of which earlier operation failed.
        if coordinator.selectedModelNeedsRevalidation { return .selectedModelUnavailable }
        if coordinator.audioFileSession && coordinator.session.phase == .failed { return .audioImportFailure }
        if coordinator.audioFileSession && coordinator.session.phase == .cancelled { return .audioImportCancelled }
        return .ready
    }
    // The same command binding is used by every mounted host; reading it has no side effect.
    @MainActor var hotkeyEnabledBinding: Binding<Bool> {
        Binding(get: { coordinator.hotkeyEnabled }, set: { coordinator.setHotkeyEnabled($0) })
    }
    private var displayedChannelBinding: Binding<Int> {
        Binding(get: { coordinator.channel + 1 }, set: { coordinator.channel = $0 - 1 })
    }
    private var statisticsNavigationBinding: Binding<Bool> {
        Binding(get: { statisticsVisible }, set: { enteringStatistics in
            if enteringStatistics && !statisticsVisible {
                // A different host can own the coordinator's recorder. Cancel
                // before this host hides Settings, even without local ownership.
                if coordinator.hotkeyRecording { coordinator.cancelHotkeyRecording() }
                ownsHotkeyRecording = false
            }
            statisticsVisible = enteringStatistics
        })
    }
    private var masthead: some View {
        HStack(spacing: 12) {
            ObservatoryMark()
                .stroke(ObservatoryAppearance.ink, style: StrokeStyle(lineWidth: 1.5,
                    lineCap: .round, lineJoin: .round))
                .frame(width: 29, height: 29)
                .accessibilityHidden(true)
            Text(ProductIdentity.displayName.lowercased())
                .font(.system(size: 20, weight: .semibold))
                .tracking(-0.5)
                .accessibilityLabel(ProductIdentity.displayName)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if coordinator.launchConfiguration.isQA {
                Button {
                    qaPreferredWidth = qaPreferredWidth == 560 ? 780 : 560
                } label: {
                    Label(ui.text("Vorschau"), systemImage: "square.dashed")
                        .font(.system(size: 11))
                        .foregroundStyle(ObservatoryAppearance.muted)
                }
                    .buttonStyle(.plain)
                    .accessibilityLabel(ui.text("Synthetischer QA-Modus"))
                    .accessibilityValue(qaCaptureOutcome ?? "")
                    .accessibilityHint(ui.text("Fensterbreite zwischen 560 und 780 wechseln. ") +
                        ui.text(coordinator.launchConfiguration.isFunctionalQA
                            ? "Synthetische Funktionsprüfung: vorbereitete Testdateien und simulierte Erkennung. Kopieren bleibt im Arbeitsspeicher; keine Aufnahme oder Modellgewichte."
                            : "Isolierte Oberflächenprüfung. Modellimport, Wiederherstellung und Aufnahme sind deaktiviert."))
                    .help(ui.text("Fensterbreite zwischen 560 und 780 wechseln."))
                    .contextMenu {
                        if AppLaunchConfiguration.isStableComparisonBundle {
                            Button(ui.text("QA-Inhaltsbild rendern")) {
                                guard !qaCaptureInFlight else { return }
                                qaCaptureInFlight = true
                                Task { @MainActor in
                                    defer { qaCaptureInFlight = false }
                                    do {
                                        let file = try QAEvidenceCapture.renderMainContent()
                                        qaCaptureOutcome = "Rendered QA content: " + file.path
                                    } catch {
                                        qaCaptureOutcome = "QA render failed: " + String(describing: error)
                                    }
                                }
                            }
                            .disabled(qaCaptureInFlight)
                            if let qaCaptureOutcome {
                                Text(qaCaptureOutcome)
                            }
                        }
                    }
            }
            if isAuxiliaryPanel {
                Button(ui.text("Fenster ausblenden"), action: coordinator.hidePanel)
                    .buttonStyle(ObservatoryActionStyle(role: .quiet))
                    .disabled(!coordinator.canHidePanel)
            }
        }
        .frame(height: 48)
        .overlay(alignment: .bottom) { ObservatoryAppearance.rule.frame(height: 1) }
    }
    private var contextBand: some View {
        Text(ui.text(coordinator.message))
            .font(.system(size: 13))
            .foregroundStyle(ObservatoryAppearance.muted)
            .lineLimit(2)
            .accessibilityAddTraits(.updatesFrequently)
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .overlay(alignment: .bottom) { ObservatoryAppearance.rule.frame(height: 1) }
    }
    private var idleCommandRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if !coordinator.busy {
                Button(ui.text("Aufnehmen"), action: coordinator.start)
                    .buttonStyle(ObservatoryActionStyle(role: coordinator.launchConfiguration.isQA
                        ? .quiet : .primary))
                    .disabled(!coordinator.canStart)
                    .help(ui.text(coordinator.launchConfiguration.isQA
                        ? "Synthetische Funktionsprüfung: vorbereitete Testdateien und simulierte Erkennung. Kopieren bleibt im Arbeitsspeicher; keine Aufnahme oder Modellgewichte."
                        : coordinator.canStart ? "Aufnahme starten" : "Aufnahme derzeit nicht bereit. Prüfe den Status oben."))
            }
            if coordinator.canStop {
                Button(ui.text("Stoppen"), action: coordinator.stop)
                    .buttonStyle(ObservatoryActionStyle(role: .secondary))
            }
            if coordinator.busy {
                Button(ui.text("Abbrechen"), action: coordinator.cancel)
                    .buttonStyle(ObservatoryActionStyle(role: .danger))
            }
            Button(ui.text("Audiodatei importieren …"), action: coordinator.importAudio)
                .buttonStyle(ObservatoryActionStyle(role: coordinator.launchConfiguration.isQA
                    ? .primary : .secondary))
                .disabled(!coordinator.canImportAudio)
            Button(ui.text("Transkript öffnen …"), action: coordinator.openTranscript)
                .buttonStyle(ObservatoryActionStyle(role: .quiet))
                .disabled(!coordinator.canOpenTranscript)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: ObservatoryAppearance.controlHeight, alignment: .leading)
    }
    private var reviewTitle: some View {
        Text(ui.text("Transkript"))
            .font(.system(size: 24, weight: .medium))
            .tracking(-0.55)
            .accessibilityAddTraits(.isHeader)
    }
    private var reviewCommandRow: some View {
        HStack(spacing: 8) {
            Button(ui.text("Kopieren"), action: coordinator.copy)
                .buttonStyle(ObservatoryActionStyle(role: .primary))
                .disabled(coordinator.editedText.isEmpty)
                .help(ui.text(coordinator.launchConfiguration.isFunctionalQA
                    ? "QA-Kopie nur im Arbeitsspeicher. Die Systemzwischenablage bleibt unverändert."
                    : "Kopieren ersetzt die Zwischenablage."))
            Button(ui.text("Transkript speichern …"), action: coordinator.saveTranscript)
                .buttonStyle(ObservatoryActionStyle(role: .secondary))
                .disabled(!coordinator.canSaveTranscript)
                .help(ui.text(coordinator.launchConfiguration.isFunctionalQA
                    ? "Synthetische QA-Vorschau: Speichern nutzt nur Testdateien; Kopieren bleibt im Arbeitsspeicher."
                    : "Ohne bewusstes Speichern bleibt die Vorschau nur im Arbeitsspeicher. Kopieren ersetzt die Zwischenablage."))
            Button(ui.text("Verwerfen"), action: coordinator.discard)
                .buttonStyle(ObservatoryActionStyle(role: .quiet))
                .disabled(coordinator.busy)
        }
    }
    /// Only action composition changes with width. The native transcript editor
    /// remains in its one persistent subtree below, with its existing review ID.
    private var phaseToolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if coordinator.session.phase == .review {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) {
                        reviewTitle
                        Spacer(minLength: 16)
                        reviewCommandRow
                    }.fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 8) {
                        reviewTitle
                        reviewCommandRow
                    }
                }
            } else {
                idleCommandRow
            }
            if !coordinator.busy {
                if coordinator.launchConfiguration.isQA && coordinator.session.phase == .idle &&
                    coordinator.microphone.state == .closed {
                    Label(ui.text("Mikrofon geschlossen · Aufnahme in Vorschau deaktiviert"), systemImage: "mic.slash")
                        .font(.system(size: 11))
                        .foregroundStyle(ObservatoryAppearance.muted)
                } else {
                    Text(ui.text(coordinator.message))
                        .font(.system(size: 11))
                        .foregroundStyle(coordinator.session.phase == .failed
                            ? ObservatoryAppearance.warning : ObservatoryAppearance.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { ObservatoryAppearance.rule.frame(height: 1) }
        .accessibilityIdentifier("clavune.phase-actions")
    }
    private var reviewEditorMinimumHeight: CGFloat {
        ObservatoryAppearance.reviewEditorMinimumHeight(utf8ByteCount:
            max(coordinator.session.rawTranscript.utf8.count, coordinator.editedText.utf8.count))
    }
    private var phaseToolbarHidden: Bool {
        settingsVisible && !coordinator.session.phase.isBusy
    }
    private func settingsHeading(_ title: String, showsDivider: Bool = true) -> some View {
        Text(ui.text(title))
            .font(.system(size: 13, weight: .medium))
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            .padding(.top, 2)
            .overlay(alignment: .bottom) {
                if showsDivider { ObservatoryAppearance.rule.frame(height: 1) }
            }
            .accessibilityAddTraits(.isHeader)
    }
    private func settingsSwitch(_ title: String, isOn: Binding<Bool>, disabled: Bool = false) -> some View {
        Toggle(title, isOn: isOn)
            .toggleStyle(ObservatoryLedgerToggleStyle(title: title,
                onLabel: ui.text("An"), offLabel: ui.text("Aus"),
                fieldWidth: ObservatoryAppearance.settingsFieldWidth))
        .disabled(disabled)
    }
    private var microphoneOptions: [(value: String, title: String)] {
        var options: [(value: String, title: String)] = [
            (value: "", title: ui.text("Systemstandard"))
        ]
        options.append(contentsOf: coordinator.devices.map { device in
            (value: device.uid, title: device.name)
        })
        return options
    }
    private var channelSettingRow: some View {
        HStack(spacing: 16) {
            Text(ui.text("Eingangskanal"))
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
            channelStepper
        }
        .disabled(coordinator.busy)
        .frame(minHeight: ObservatoryAppearance.settingRowHeight)
    }
    private var channelStepper: some View {
        HStack(spacing: 0) {
            Text(String(displayedChannelBinding.wrappedValue))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)
            Button { displayedChannelBinding.wrappedValue -= 1 } label: {
                Text("−").font(.system(size: 15, weight: .medium, design: .monospaced))
                    .frame(width: 10, height: 16)
            }
            .disabled(displayedChannelBinding.wrappedValue <= 1)
            .accessibilityLabel(ui.text("Eingangskanal verringern"))
            Button { displayedChannelBinding.wrappedValue += 1 } label: {
                Text("+").font(.system(size: 15, weight: .medium, design: .monospaced))
                    .frame(width: 10, height: 16)
            }
            .disabled(displayedChannelBinding.wrappedValue >= 32)
            .accessibilityLabel(ui.text("Eingangskanal erhöhen"))
        }
        .buttonStyle(ObservatoryActionStyle(role: .quiet))
        .padding(.leading, 10)
        .frame(width: ObservatoryAppearance.settingsFieldWidth)
        .frame(minHeight: ObservatoryAppearance.controlHeight)
        .background(ObservatoryAppearance.surface, in: RoundedRectangle(cornerRadius: 4))
        .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(ObservatoryAppearance.rule) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ui.text("Eingangskanal"))
        .accessibilityValue(String(displayedChannelBinding.wrappedValue))
        .accessibilityAdjustableAction { adjustChannel($0) }
    }
    private func adjustChannel(_ direction: AccessibilityAdjustmentDirection) {
        guard !coordinator.busy else { return }
        switch direction {
        case .increment where displayedChannelBinding.wrappedValue < 32:
            displayedChannelBinding.wrappedValue += 1
        case .decrement where displayedChannelBinding.wrappedValue > 1:
            displayedChannelBinding.wrappedValue -= 1
        default: break
        }
    }
    private var modelImportButton: some View {
        Button(ui.text("Modell importieren …"), action: coordinator.importModel)
            .buttonStyle(ObservatoryActionStyle(role: .secondary))
            .disabled(coordinator.busy || coordinator.isPresentationQA)
    }
    private var modelUnloadButton: some View {
        Button(ui.text("Modell entladen"), action: coordinator.unload)
            .buttonStyle(ObservatoryActionStyle(role: .secondary))
            .disabled(coordinator.busy || coordinator.launchConfiguration.isQA)
    }
    private var modelRestoreButton: some View {
        Button(ui.text("Gespeichertes Modell erneut prüfen"), action: coordinator.restoreManagedModel)
            .buttonStyle(ObservatoryActionStyle(role: .quiet))
            .disabled(!coordinator.canRestoreManagedModel)
    }
    private var modelActionRow: some View {
        HStack(spacing: 8) {
            modelImportButton
            modelUnloadButton
            modelRestoreButton
        }
        .fixedSize(horizontal: true, vertical: false)
    }
    var body: some View {
        VStack(spacing: 0) {
            masthead
            if (!settingsVisible && coordinator.busy) || coordinator.session.phase.isBusy { contextBand }
            ObservatoryNavigationSegments(
                settingsVisible: $settingsVisible,
                statisticsVisible: statisticsNavigationBinding,
                accessibilityTitle: ui.text("Ansicht"),
                dictationTitle: ui.text("Diktat"),
                settingsTitle: ui.text("Einstellungen"),
                statisticsTitle: ui.text("Statistiken"))
                .frame(width: 300, height: ObservatoryAppearance.navigationHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(alignment: .bottom) { ObservatoryAppearance.rule.frame(height: 1) }
            // Pinned actions are outside the content scroller. Hiding this
            // toolbar never conditionally replaces the editor below.
            phaseToolbar
                .frame(height: phaseToolbarHidden ? 0 : nil, alignment: .top)
                .clipped()
                .opacity(phaseToolbarHidden ? 0 : 1)
                .disabled(phaseToolbarHidden)
                .allowsHitTesting(!phaseToolbarHidden)
                .accessibilityHidden(phaseToolbarHidden)
            ScrollView {
            VStack(alignment: .leading, spacing: 12) {
            if !coordinator.launchConfiguration.isQA && coordinator.model == nil &&
                coordinator.modelStatus != "Kein Modell importiert" {
                Text(ui.text(coordinator.modelStatus)).font(.system(size: 11))
                    .accessibilityAddTraits(.updatesFrequently)
            }
            if coordinator.session.phase == .recording || coordinator.session.phase == .stopping {
                CaptureProgressView(state: coordinator.capturePresentation,
                    sessionLimitSeconds: coordinator.policy.sessionLimitSeconds,
                    channel: coordinator.channel, uiLanguage: ui)
            }
            // Keep this host's current review/editor identity alive across navigation.
            // Replacing the review still changes .id below and tears down its Undo stack.
            ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 10) {
            if coordinator.session.phase == .review {
                reviewStatusStrip
                TranscriptEditor(text: $coordinator.editedText, isPresented: !settingsVisible,
                    reviewCoordinator: coordinator, reviewID: coordinator.session.id,
                    clipboardWriteSink: coordinator.qaTranscriptClipboardSink)
                    .id(coordinator.session.id) // A newly opened review starts a fresh native Undo history.
                    .disabled(coordinator.transcriptFilePending)
                    .frame(minHeight: reviewEditorMinimumHeight)
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(ObservatoryAppearance.rule, lineWidth: 1)
                            .accessibilityHidden(true)
                            .allowsHitTesting(false)
                    }
                    .overlay {
                        ObservatoryTranscriptCornerFrame()
                            .stroke(ObservatoryAppearance.ink.opacity(0.48),
                                    style: StrokeStyle(lineWidth: 1.25, lineCap: .square))
                            .accessibilityHidden(true)
                            .allowsHitTesting(false)
                    }
                    .accessibilityLabel(ui.text("Bearbeitbare Transkriptvorschau"))
                DisclosureGroup(ui.text("Unveränderter Ausgangstext")) {
                    TranscriptEditor(text: .constant(coordinator.session.rawTranscript), isEditable: false,
                        isPresented: !settingsVisible, clipboardWriteSink: coordinator.qaTranscriptClipboardSink)
                        .frame(minHeight: 70, maxHeight: 100)
                        .accessibilityLabel(ui.text("Unveränderter Ausgangstext, auswählbar und kopierbar"))
                }
                .font(.system(size: 12))
                .foregroundStyle(ObservatoryAppearance.muted)
            } else {
                switch guidanceMode {
                case .hidden:
                    EmptyView()
                case .recovery:
                    if let recovery = coordinator.dictationRecovery {
                        DictationRecoveryView(coordinator: coordinator, recovery: recovery,
                            openSettings: { settingsVisible = true })
                    }
                case .audioImportFailure, .audioImportCancelled:
                    VStack(alignment: .leading, spacing: 12) {
                        Text(ui.text("Dateiimport nicht abgeschlossen")).font(.title3.weight(.medium))
                        Text(ui.text("Mikrofoneingabe bleibt geschlossen. Wähle oben „Audiodatei importieren …“, um es erneut zu versuchen."))
                            .foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
                case .selectedModelUnavailable:
                    VStack(alignment: .leading, spacing: 12) {
                        Text(ui.text("Ausgewähltes Modell nicht bereit")).font(.title3.weight(.medium))
                        Text(ui.text("Die ausgewählte Modelldatei ist nicht mehr gültig oder verfügbar. Aufnahme bleibt gesperrt. Prüfe das Modell erneut oder wähle in den Einstellungen eine andere Datei."))
                            .foregroundStyle(.secondary)
                        Button(ui.text("Einstellungen")) { settingsVisible = true }
                            .buttonStyle(ObservatoryActionStyle(role: .secondary))
                    }.frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
                case .ready:
                    if !coordinator.launchConfiguration.isQA {
                    VStack(alignment: .leading, spacing: 12) {
                        if coordinator.model == nil {
                            ModelImportGuidance(catalogue: coordinator.modelCatalogue, ui: ui,
                                selectedModelSHA256: nil,
                                verifiedInstalledModelHashes: coordinator.verifiedInstalledModelHashes,
                                localModelInventoryChecked: coordinator.localModelInventoryChecked,
                                isBusy: coordinator.busy,
                                onDownload: coordinator.downloadModel,
                                onCheckInstalled: coordinator.checkInstalledModels,
                                onSelectInstalled: coordinator.selectInstalledModel, isSetup: true,
                                allowsDownload: !coordinator.isPresentationQA,
                                allowsTextSelection: !coordinator.launchConfiguration.isQA)
                            Button(ui.text("Modell importieren …"), action: coordinator.importModel)
                                .disabled(coordinator.busy || coordinator.isPresentationQA)
                            Button(ui.text("Einstellungen")) { settingsVisible = true }
                                .buttonStyle(ObservatoryActionStyle(role: .secondary))
                        } else if let model = coordinator.model {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(model.fileName)
                                    .font(.system(size: 11, design: .monospaced))
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 8)
                                Text(ui.text(coordinator.language.title))
                                    .font(.system(size: 11))
                            }
                            .foregroundStyle(ObservatoryAppearance.muted)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                }
            }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: settingsVisible ? 0 : nil, alignment: .top)
            .clipped()
            .opacity(settingsVisible ? 0 : 1)
            .disabled(settingsVisible)
            .allowsHitTesting(!settingsVisible)
            .accessibilityHidden(settingsVisible)
            if settingsVisible && !statisticsVisible {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ui.text("Einstellungen"))
                        .font(.system(size: 22, weight: .regular))
                        .tracking(-0.4)
                        .accessibilityAddTraits(.isHeader)
                    settingsHeading("Allgemein")
                    ObservatorySettingChoice(title: ui.text("Oberflächensprache"),
                        selection: $coordinator.uiLanguage,
                        options: [(value: UILanguage.english, title: ui.text("English")),
                                  (value: .german, title: ui.text("Deutsch"))],
                        fieldWidth: ObservatoryAppearance.settingsFieldWidth)
                    settingsSwitch(ui.text("In der Menüleiste anzeigen"),
                        isOn: $coordinator.menuBarEnabled)
                    settingsHeading("Modell")
                    if !coordinator.launchConfiguration.isQA {
                        Text(ui.text(coordinator.modelStatus)).font(.caption).textSelection(.enabled)
                    }
                    ModelImportGuidance(catalogue: coordinator.modelCatalogue, ui: ui,
                        selectedModelSHA256: coordinator.model?.sha256,
                        verifiedInstalledModelHashes: coordinator.verifiedInstalledModelHashes,
                        localModelInventoryChecked: coordinator.localModelInventoryChecked,
                        isBusy: coordinator.busy,
                        onDownload: coordinator.downloadModel,
                        onCheckInstalled: coordinator.checkInstalledModels,
                        onSelectInstalled: coordinator.selectInstalledModel,
                        allowsDownload: !coordinator.isPresentationQA,
                        allowsTextSelection: !coordinator.launchConfiguration.isQA)
                        .font(.system(size: 12))
                        .buttonStyle(ObservatoryActionStyle(role: .secondary))
                    if coordinator.launchConfiguration.isQA {
                        Text(ui.text("Vorschau · Modellaktionen deaktiviert; keine Gewichte geladen"))
                            .font(.caption)
                            .foregroundStyle(ObservatoryAppearance.muted)
                    } else {
                        ViewThatFits(in: .horizontal) {
                            modelActionRow
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    modelImportButton
                                    modelUnloadButton
                                }
                                modelRestoreButton
                            }
                        }
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        settingsHeading("Eingabe", showsDivider: false)
                        Button(ui.text("Geräte aktualisieren"), action: coordinator.refreshDevices)
                            .buttonStyle(ObservatoryActionStyle(role: .quiet))
                            .disabled(coordinator.busy)
                    }
                    .overlay(alignment: .bottom) { ObservatoryAppearance.rule.frame(height: 1) }
                    ObservatorySettingChoice(title: ui.text("Erkennungssprache"),
                        selection: $coordinator.language,
                        options: LanguageMode.allCases.map { (value: $0, title: ui.text($0.title)) },
                        fieldWidth: ObservatoryAppearance.settingsFieldWidth)
                        .disabled(coordinator.busy)
                    ObservatorySettingChoice(title: ui.text("Mikrofon"),
                        selection: $coordinator.deviceUID,
                        options: microphoneOptions, fieldWidth: ObservatoryAppearance.settingsFieldWidth)
                        .disabled(coordinator.busy)
                    channelSettingRow
                    settingsHeading("Tastenkürzel")
                    HStack(alignment: .top, spacing: 16) {
                        Text(ui.text("Aktuelles Tastenkürzel"))
                            .font(.system(size: 13))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                        // Keep the shortcut and the actions that change it in
                        // one value column, rather than opposite page edges.
                        VStack(alignment: .leading, spacing: 6) {
                            Text(ui.text(coordinator.developmentShortcut.title))
                                .font(.system(size: 12, weight: .regular, design: .monospaced))
                                .padding(.horizontal, 10)
                                .frame(width: ObservatoryAppearance.settingsFieldWidth, alignment: .leading)
                                .frame(minHeight: ObservatoryAppearance.controlHeight, alignment: .leading)
                                .background(ObservatoryAppearance.surface, in: RoundedRectangle(cornerRadius: 4))
                            Button(ui.text("Tastenkürzel aufnehmen …")) {
                                ownsHotkeyRecording = coordinator.beginHotkeyRecording()
                            }
                            .buttonStyle(ObservatoryActionStyle(role: .secondary))
                            .disabled(coordinator.busy || coordinator.launchConfiguration.isQA)
                            if ownsHotkeyRecording && coordinator.hotkeyRecording {
                                Button(ui.text("Tastenkürzelaufnahme abbrechen")) {
                                    coordinator.cancelHotkeyRecording()
                                    ownsHotkeyRecording = false
                                }
                                .buttonStyle(ObservatoryActionStyle(role: .quiet))
                            }
                        }
                        .frame(width: ObservatoryAppearance.settingsFieldWidth, alignment: .leading)
                    }
                    .frame(minHeight: ObservatoryAppearance.settingRowHeight)
                    if ownsHotkeyRecording && coordinator.hotkeyRecording {
                        FocusedHotkeyRecorder(
                            accessibilityTitle: ui.text("Tastenkürzel eingeben"),
                            onChord: { keyCode, modifiers in
                                if coordinator.acceptRecordedHotkey(keyCode: keyCode, modifiers: modifiers) {
                                    ownsHotkeyRecording = false
                                }
                            },
                            onCancel: {
                                coordinator.cancelHotkeyRecording()
                                ownsHotkeyRecording = false
                            },
                            onPendingChange: { coordinator.setHotkeyChordPending($0) },
                            onFocusLost: { hadPending in
                                if coordinator.hotkeyRecording {
                                    if hadPending { coordinator.interruptForPrivacy() }
                                    else { coordinator.cancelHotkeyRecording() }
                                }
                                ownsHotkeyRecording = false
                            })
                            .frame(height: 28)
                        Text(ui.text("Drücke Ctrl–Shift oder Cmd–Shift mit Leertaste/F6–F19; Escape bricht ab."))
                            .font(.caption)
                    }
                    if !coordinator.launchConfiguration.isQA {
                        Text(ui.text("Ctrl–Option–Leertaste bleibt für VoiceOver reserviert. Weitere System- oder App-Konflikte können bestehen.")).font(.caption)
                    }
                    if !coordinator.launchConfiguration.isQA {
                        settingsSwitch(ui.text("Globalen Hotkey aktivieren (Entwicklung)"),
                            isOn: hotkeyEnabledBinding,
                            disabled: coordinator.busy)
                    }
                    settingsSwitch(ui.text("Halten zum Sprechen"),
                        isOn: $coordinator.holdToTalk, disabled: coordinator.busy)
                    if !coordinator.launchConfiguration.isQA {
                        Text(ui.text(coordinator.hotkeyStatus)).font(.caption)
                        Text(String(format: ui.text("Sitzungslimit: %d s. Keine Cloud-Inferenz, kein automatischer Verlauf. Qualitäts- und Gerätetests stehen noch aus."), coordinator.policy.sessionLimitSeconds))
                            .font(.caption)
                    }
                }
                .frame(maxWidth: ObservatoryAppearance.settingsColumnWidth, alignment: .leading)
                // Keep a deliberate reading column at both window widths,
                // rather than pinning the same narrow form to the wide canvas edge.
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 4)
            }
            if statisticsVisible {
                LocalStatisticsPageView(model: statistics, ui: ui,
                    qaDisabled: coordinator.launchConfiguration.isQA && !statisticsPreviewInQA,
                    isSyntheticPreview: statisticsPreviewInQA)
            }
            }
            if settingsVisible && !statisticsVisible, let metrics = coordinator.metrics {
                DisclosureGroup(ui.text("Lokale Messpunkte")) {
                    VStack(alignment: .leading) {
                        Text(String(format: ui.text("PCM: %@ Abtastwerte"), String(metrics.frames16k)))
                        Text(ui.text("Backend-Prüfsumme") + ": \(metrics.backendFingerprint)").font(.caption.monospaced())
                        if let seconds = metrics.modelLoadSeconds { Text(String(format: ui.text("Modellladen: %.3f s (%@)"), seconds, metrics.modelWarm ? "warm" : ui.text("kalt"))) }
                        if let seconds = metrics.audioPreparationSeconds { Text(String(format: ui.text("Datei dekodieren/konvertieren: %.3f s"), seconds)) }
                        if let seconds = metrics.decodeSeconds { Text(String(format: ui.text("Batch-Aufruf: %.3f s"), seconds)) }
                        if let seconds = metrics.audioImportTotalSeconds { Text(String(format: ui.text("Importstart bis Ergebnis: %.3f s"), seconds)) }
                        Text(ui.text("Einfügen, Energie, Gesamtspeicher und Qualitätsvergleich: ungemessen"))
                    }.font(.caption)
                }
                .frame(maxWidth: ObservatoryAppearance.settingsColumnWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(.top, settingsVisible && !statisticsVisible ? 2 : 12)
        .padding(.bottom, settingsVisible && !statisticsVisible ? 28 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(settingsVisible && !statisticsVisible ? .visible : .automatic)
        // Both secondary pages share real space outside their viewport, not a
        // content mask. The navigation supplies the single upper boundary rule.
        .padding(.vertical, settingsVisible ? ObservatoryAppearance.scrollViewportGutter : 0)
        }
        .padding(.horizontal, isAuxiliaryPanel ? 18 : 22)
        .frame(maxWidth: 920)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minHeight: qaWindowHeight)
        .background {
            if let qaWindowHeight {
                QAAdaptiveWindowSize(contentHeight: qaWindowHeight, preferredWidth: qaPreferredWidth)
            }
        }
        .background(ObservatoryAppearance.canvas)
        .foregroundStyle(ObservatoryAppearance.ink)
        .preferredColorScheme(.dark)
        .onChange(of: settingsVisible) { _, isVisible in
            if !isVisible && ownsHotkeyRecording {
                coordinator.cancelHotkeyRecording()
                ownsHotkeyRecording = false
            }
        }
        .onChange(of: coordinator.hotkeyRecording) { _, isRecording in
            if !isRecording { ownsHotkeyRecording = false }
        }
        .onDisappear {
            if ownsHotkeyRecording {
                coordinator.cancelHotkeyRecording()
                ownsHotkeyRecording = false
            }
        }
    }
}

/// A native segmented control keeps its localized picker label on the actual AX element.
struct LocalizedNavigationSegments: NSViewRepresentable {
    @Binding var settingsVisible: Bool
    @Binding var statisticsVisible: Bool
    let accessibilityTitle: String
    let dictationTitle: String
    let settingsTitle: String
    let statisticsTitle: String?

    init(settingsVisible: Binding<Bool>, statisticsVisible: Binding<Bool> = .constant(false),
         accessibilityTitle: String, dictationTitle: String, settingsTitle: String,
         statisticsTitle: String? = nil) {
        _settingsVisible = settingsVisible
        _statisticsVisible = statisticsVisible
        self.accessibilityTitle = accessibilityTitle
        self.dictationTitle = dictationTitle
        self.settingsTitle = settingsTitle
        self.statisticsTitle = statisticsTitle
    }

    private var selectedIndex: Int { settingsVisible ? (statisticsTitle != nil && statisticsVisible ? 2 : 1) : 0 }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> AccessibleSegments {
        let labels = [dictationTitle, settingsTitle] + (statisticsTitle.map { [$0] } ?? [])
        let control = AccessibleSegments(labels: labels,
            trackingMode: .selectOne, target: context.coordinator,
            action: #selector(Coordinator.selectionChanged(_:)))
        control.localizedAccessibilityTitle = accessibilityTitle
        control.selectedSegment = selectedIndex
        return control
    }

    func updateNSView(_ control: AccessibleSegments, context: Context) {
        let enteringHiddenSection = context.coordinator.previousIndex != selectedIndex && selectedIndex != 0
        context.coordinator.parent = self
        control.setLabel(dictationTitle, forSegment: 0)
        control.setLabel(settingsTitle, forSegment: 1)
        if let statisticsTitle, control.segmentCount > 2 { control.setLabel(statisticsTitle, forSegment: 2) }
        control.localizedAccessibilityTitle = accessibilityTitle
        control.selectedSegment = selectedIndex
        if enteringHiddenSection, let window = control.window {
            // Either hidden section may replace a focused editor/settings control.
            // Hand focus to persistent navigation rather than leaving it in hidden content.
            _ = window.makeFirstResponder(control)
        }
        context.coordinator.previousIndex = selectedIndex
    }

    final class AccessibleSegments: NSSegmentedControl {
        var localizedAccessibilityTitle: String?

        override func accessibilityLabel() -> String? {
            localizedAccessibilityTitle ?? super.accessibilityLabel()
        }
    }

    @MainActor final class Coordinator: NSObject {
        var parent: LocalizedNavigationSegments
        var previousIndex: Int
        init(_ parent: LocalizedNavigationSegments) {
            self.parent = parent
            previousIndex = parent.selectedIndex
        }

        @objc func selectionChanged(_ sender: NSSegmentedControl) {
            guard sender.selectedSegment >= 0, sender.selectedSegment < sender.segmentCount else { return }
            if sender.selectedSegment != 0, !parent.settingsVisible,
               let editor = sender.window?.firstResponder as? PlainTranscriptTextView,
               editor.hasMarkedText() {
                // Commit before changing SwiftUI state. Doing this from updateNSView
                // publishes through the editor binding during a view update.
                editor.unmarkText()
            }
            parent.statisticsVisible = sender.selectedSegment == 2
            parent.settingsVisible = sender.selectedSegment != 0
        }
    }
}

/// This leaf alone observes live progress. The coordinator still owns all actions.
struct CaptureProgressView: View {
    @ObservedObject var state: CapturePresentationState
    let sessionLimitSeconds: Int
    let channel: Int
    var uiLanguage: UILanguage = .english
    private var ui: UILanguage { uiLanguage }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(format: ui.text("%.1f / %d s — Kanal %d"), state.sample.seconds,
                        sessionLimitSeconds, channel + 1))
                .monospacedDigit()
            ProgressView(value: Double(state.sample.peak), total: 1)
                .accessibilityLabel(ui.text("Mikrofonpegel"))
        }
    }
}

struct TranscriptEditor: NSViewRepresentable {
    @Binding var text: String
    @Environment(\.isEnabled) private var isEnabled
    var isEditable = true
    var isPresented = true
    var reviewCoordinator: AppCoordinator? = nil
    var reviewID: UUID? = nil
    var clipboardWriteSink: (any ClipboardWriteSink)? = nil
    func makeCoordinator() -> Delegate { Delegate(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let editor = PlainTranscriptTextView(frame: .zero)
        editor.clipboardWriteSink = clipboardWriteSink
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        // A legacy scroller stays visible for real overflow rather than fading
        // over the last text column; autohide still removes it for short text.
        scroll.scrollerStyle = .legacy
        scroll.scrollerKnobStyle = .light
        scroll.drawsBackground = true
        scroll.backgroundColor = ObservatoryAppearance.editorBackground
        scroll.documentView = editor
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.isRichText = false; editor.allowsUndo = isEditable
        editor.isEditable = isEditable && isEnabled && isPresented
        editor.isSelectable = isPresented; scroll.isHidden = !isPresented
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticTextCompletionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.textContainerInset = NSSize(width: 12, height: 12)
        editor.font = .systemFont(ofSize: 15)
        editor.drawsBackground = true
        editor.backgroundColor = ObservatoryAppearance.editorBackground
        editor.textColor = ObservatoryAppearance.editorInk
        editor.insertionPointColor = ObservatoryAppearance.editorInk
        editor.delegate = context.coordinator
        context.coordinator.attach(to: editor)
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        if let editor = view.documentView as? PlainTranscriptTextView {
            // Release native focus before replacing the editor's current binding
            // and presentation flags. The picker action commits marked text first.
            if !isPresented, let window = editor.window, window.firstResponder === editor {
                window.makeFirstResponder(nil)
            }
            context.coordinator.parent = self
            editor.clipboardWriteSink = clipboardWriteSink
            // AppKit can hold uncommitted marked text without publishing a
            // textDidChange. A resize/language refresh must not restore the old
            // binding over that live composition, or reconfigure its editability.
            // Read after focus handoff above: resigning can commit the composition.
            let incomingText = text
            if context.coordinator.preserveMarkedText(in: editor, incomingText: incomingText) {
                return
            }
            editor.isEditable = isEditable && isEnabled && isPresented
            editor.isSelectable = isPresented; view.isHidden = !isPresented
            if !TranscriptTextIdentity.matches(editor.string, incomingText) {
                // A genuinely different external draft still replaces local
                // storage, including an obsolete composition and its Undo ranges.
                context.coordinator.clearUndoHistory()
                editor.string = incomingText
                // Replacing active marked text can register its teardown as a
                // native undo operation. That operation also belongs to the old
                // draft, so finish invalidation after AppKit's replacement.
                context.coordinator.clearUndoHistory()
            }
            context.coordinator.recordSynchronizedText(incomingText)
        }
    }
    static func dismantleNSView(_ view: NSScrollView, coordinator: Delegate) {
        (view.documentView as? NSTextView)?.delegate = nil
        coordinator.detach()
    }
    @MainActor
    final class Delegate: NSObject, NSTextViewDelegate {
        var parent: TranscriptEditor
        private weak var reviewCoordinator: AppCoordinator?
        private let reviewID: UUID?
        // Each editor/review owns its Undo stack, not the surrounding window or another host.
        private let reviewUndoManager = UndoManager()
        private weak var editor: NSTextView?
        // Last exact binding value applied to this native view or published by
        // this delegate. This distinguishes a refresh from another host's edit.
        private var synchronizedText: String?
        private var selectionBeforeChange: NSRange?
        private var selectionToRestoreAfterHistoryChange: NSRange?
        init(_ parent: TranscriptEditor) {
            self.parent = parent
            reviewCoordinator = parent.reviewCoordinator
            reviewID = parent.reviewID
        }
        func attach(to editor: NSTextView) {
            self.editor = editor
            guard parent.isEditable else { return }
            reviewCoordinator?.registerReviewEditor(self)
            for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
                NotificationCenter.default.addObserver(self, selector: #selector(historyDidChange(_:)),
                    name: name, object: reviewUndoManager)
            }
        }
        func detach() {
            NotificationCenter.default.removeObserver(self)
            reviewCoordinator?.unregisterReviewEditor(self)
            editor = nil
            clearUndoHistory()
        }
        deinit { NotificationCenter.default.removeObserver(self) }
        func undoManager(for view: NSTextView) -> UndoManager? {
            parent.isEditable ? reviewUndoManager : nil
        }
        func recordSynchronizedText(_ text: String) {
            synchronizedText = text
        }
        enum PendingSaveCommit { case none, text(String), blocked }
        func pendingSaveCommit(reviewID: UUID?, boundText: String) -> PendingSaveCommit {
            guard self.reviewID == reviewID, parent.isEditable,
                  let editor, editor.hasMarkedText() else { return .none }
            guard parent.isEnabled, parent.isPresented, editor.isEditable,
                  editor.delegate === self,
                  synchronizedText.map({ TranscriptTextIdentity.matches($0, boundText) }) == true ||
                    TranscriptTextIdentity.matches(editor.string, boundText) else { return .blocked }
            return .text(editor.string)
        }
        func commitPendingSaveText(_ expected: String) -> Bool {
            guard let editor, editor.delegate === self, parent.isEditable,
                  parent.isEnabled, parent.isPresented, editor.isEditable else { return false }
            editor.unmarkText()
            // AppKit need not send textDidChange for every marked-text boundary.
            // Use this editor's normal publisher, not a synthetic notification.
            publishText(from: editor)
            return TranscriptTextIdentity.matches(editor.string, expected) &&
                TranscriptTextIdentity.matches(parent.text, expected)
        }
        func preserveMarkedText(in textView: NSTextView, incomingText: String) -> Bool {
            guard textView === editor, parent.isEditable, parent.isEnabled, parent.isPresented,
                  textView.isEditable, textView.hasMarkedText() else { return false }
            let sameBinding = synchronizedText.map {
                TranscriptTextIdentity.matches($0, incomingText)
            } ?? false
            guard sameBinding || TranscriptTextIdentity.matches(textView.string, incomingText) else {
                return false
            }
            recordSynchronizedText(incomingText)
            return true
        }
        func clearUndoHistory() {
            reviewUndoManager.removeAllActions()
            selectionBeforeChange = nil
            selectionToRestoreAfterHistoryChange = nil
        }
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                      replacementString: String?) -> Bool {
            guard textView === editor, parent.isEditable, parent.isEnabled, parent.isPresented,
                  !reviewUndoManager.isUndoing, !reviewUndoManager.isRedoing else {
                selectionBeforeChange = nil
                return true
            }
            selectionBeforeChange = textView.selectedRange()
            return true
        }
        func textDidChange(_ note: Notification) {
            guard let changed = note.object as? NSTextView, changed === editor else { return }
            if reviewUndoManager.isUndoing || reviewUndoManager.isRedoing {
                selectionBeforeChange = nil
            } else if let before = selectionBeforeChange {
                let after = changed.selectedRange()
                if before != after {
                    registerSelectionHistory(before: before, after: after)
                }
                selectionBeforeChange = nil
            }
            publishText(from: changed)
        }
        @objc private func historyDidChange(_ note: Notification) {
            // Custom-manager Undo may finish changing native storage before a
            // textDidChange reaches us. Publish at its real completion boundary,
            // never by polling or synthesizing an AppKit editing notification.
            guard let editor else { return }
            publishText(from: editor)
            if let selection = selectionToRestoreAfterHistoryChange {
                selectionToRestoreAfterHistoryChange = nil
                let length = (editor.string as NSString).length
                if selection.location != NSNotFound, NSMaxRange(selection) <= length {
                    editor.setSelectedRange(selection)
                }
            }
        }
        private func registerSelectionHistory(before: NSRange, after: NSRange) {
            reviewUndoManager.registerUndo(withTarget: self) { target in
                target.applySelectionHistory(before: before, after: after)
            }
        }
        private func applySelectionHistory(before: NSRange, after: NSRange) {
            if reviewUndoManager.isUndoing {
                selectionToRestoreAfterHistoryChange = before
            } else if reviewUndoManager.isRedoing {
                selectionToRestoreAfterHistoryChange = after
            } else {
                return
            }
            reviewUndoManager.registerUndo(withTarget: self) { target in
                target.applySelectionHistory(before: before, after: after)
            }
        }
        private func publishText(from editor: NSTextView) {
            guard parent.isEditable && parent.isEnabled && parent.isPresented, editor.isEditable,
                  editor.delegate === self else { return }
            let text = editor.string
            // Record before the binding write; it may synchronously refresh this host.
            recordSynchronizedText(text)
            guard !TranscriptTextIdentity.matches(parent.text, text) else { return }
            parent.text = text
        }
    }
}

@MainActor
protocol RecordingPanelPresenting: AnyObject {
    func show(force: Bool)
    func hide()
}

@MainActor
final class RecordingPanelController: RecordingPanelPresenting {
    private let panel: NSPanel
    init(coordinator: AppCoordinator) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 580),
                        styleMask: [.titled, .nonactivatingPanel, .utilityWindow, .resizable], backing: .buffered, defer: false)
        panel.title = ProductIdentity.displayName
        panel.level = .floating; panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: DictationView(coordinator: coordinator, isAuxiliaryPanel: true))
        panel.center()
    }
    func show(force: Bool = false) {
        // A visible desktop window already presents the shared session. The panel
        // remains an auxiliary surface for hidden-window/global-shortcut use.
        guard force || !NSApp.windows.contains(where: { $0.identifier?.rawValue == "clavune.main" && $0.isVisible }) else { return }
        panel.orderFrontRegardless()
    }
    func hide() { panel.orderOut(nil) }
}
