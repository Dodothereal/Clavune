import AppKit
import ClavuneCore
import Foundation
import SwiftUI

/// A functional, deliberately refreshed view of local metrics. The isolated
/// QA app injects fixed in-memory events and never opens a personal journal.
struct LocalStatisticsPageView: View {
    @ObservedObject var model: LocalStatisticsPageModel
    let ui: UILanguage
    let qaDisabled: Bool
    let isSyntheticPreview: Bool
    private var plotText: LocalStatisticsPlotText { LocalStatisticsPlotText(english: ui == .english) }
    @StateObject private var exportController: LocalStatisticsExportController

    @MainActor init(model: LocalStatisticsPageModel, ui: UILanguage, qaDisabled: Bool,
                    isSyntheticPreview: Bool = false,
                    exportEnvironment: LocalStatisticsExportEnvironment = .production,
                    exportGate: LocalStatisticsExportGate? = nil) {
        self.model = model
        self.ui = ui
        self.qaDisabled = qaDisabled
        self.isSyntheticPreview = isSyntheticPreview
        _exportController = StateObject(wrappedValue:
            LocalStatisticsExportController(environment: exportEnvironment, gate: exportGate))
    }

    @MainActor private var exportInput: LocalStatisticsJSONExport.Input? {
        guard !qaDisabled && !isSyntheticPreview else { return nil }
        return LocalStatisticsJSONExport.Input(state: model.state, selection: model.selectedPeriod)
    }

    private var periodBinding: Binding<LocalStatisticsPeriod> {
        Binding(get: { model.selectedPeriod },
                set: { _ = model.selectPeriod($0, qaDisabled: qaDisabled) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(ui.text("Lokale Statistik"))
                    .font(.system(size: 22, weight: .regular))
                    .tracking(-0.4)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
            }
            if isSyntheticPreview {
                Text(plotText.previewProvenance)
                    .font(.system(size: 11))
                    .foregroundStyle(ObservatoryAppearance.muted)
            }
            if !qaDisabled {
                if !isSyntheticPreview {
                    Text(ui.text("Nur bereits lokal gespeicherte, inhaltsfreie Messpunkte. Kein Audio, Transkript oder Dateipfad wird hier angezeigt."))
                        .font(.caption).foregroundStyle(ObservatoryAppearance.muted)
                }
                HStack(spacing: 8) {
                    ObservatorySettingChoice(title: ui.text("Zeitraum"), selection: periodBinding,
                        options: LocalStatisticsPeriod.allCases.map {
                            (value: $0, title: ui.text($0.titleKey))
                        })
                    Button {
                        _ = model.refresh(qaDisabled: qaDisabled)
                    } label: {
                        Image(systemName: "arrow.clockwise").frame(width: 18, height: 18)
                    }
                    .buttonStyle(ObservatoryActionStyle(role: .secondary))
                    .accessibilityLabel(ui.text("Statistik aktualisieren"))
                    .help(ui.text("Statistik aktualisieren"))
                }
                .padding(8)
                .background(ObservatoryAppearance.raised.opacity(0.42),
                            in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(ObservatoryAppearance.rule, lineWidth: 1)
                        .accessibilityHidden(true)
                }
            }
            switch model.state {
            case .notLoaded:
                if !isSyntheticPreview {
                    Text(ui.text("Noch kein lokaler Messpunkt-Schnappschuss geladen."))
                }
            case .loading:
                ProgressView(ui.text(isSyntheticPreview ? "Beispiel wird erstellt …" :
                    "Lokale Statistik wird gelesen …"))
            case .qaUnavailable:
                Text(ui.text("Im QA-Modus werden normale lokale Nutzungsdaten nicht gelesen."))
                    .foregroundStyle(ObservatoryAppearance.muted)
            case .failed(let failure):
                Label(ui.text(isSyntheticPreview ? "Beispiel nicht verfügbar." : failure.messageKey),
                      systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
            case .empty(let result):
                Text(ui.text(isSyntheticPreview ? "Keine Beispielereignisse in diesem Zeitraum." :
                    "Für diesen Zeitraum wurden keine auswertbaren lokalen Einträge gefunden. Das belegt keine Nutzung von null."))
                    .foregroundStyle(.secondary)
                if !isSyntheticPreview { snapshotFooter(result) }
            case .populated(let result):
                reportContent(result)
            case .partial(let result):
                Label(ui.text(isSyntheticPreview ? "Beispieldaten konnten nicht vollständig ausgewertet werden." :
                    "Nur ein Teil der gespeicherten Messpunkte war auswertbar. Die Werte unten sind vorläufig."),
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                if result.hasEventsInPeriod { reportContent(result) }
                else {
                    Text(ui.text("Kein auswertbarer Eintrag in diesem Zeitraum; beschädigte oder fehlende Daten sind möglich."))
                    if !isSyntheticPreview { snapshotFooter(result) }
                }
                diagnosticContent(result)
            }
            if !qaDisabled && !isSyntheticPreview {
                Button(ui.text("Angezeigten Statistikbericht als JSON exportieren …")) {
                    guard let input = exportInput else { return }
                    let exporter = exportController, language = ui
                    Task { await exporter.export(input, ui: language) }
                }
                .disabled(exportInput == nil || exportController.state.isBusy)
                .buttonStyle(ObservatoryActionStyle(role: .secondary))
                Text(ui.text("Nur auf deinen Befehl: Der JSON-Bericht enthält aggregierte Nutzungszeiten und Zählwerte, keinen Transkripttext. Der gewählte Ordner kann synchronisiert werden."))
                    .font(.caption).foregroundStyle(ObservatoryAppearance.muted)
                exportStatus
            }
            if !qaDisabled && !isSyntheticPreview {
                Text(ui.text("Die historische Abdeckung ist unbekannt: Aufzeichnung kann wegen Grenzen oder Fehlern fehlen. Starts und Ergebnisse werden nach ihren jeweiligen Zeitpunkten gezählt und müssen sich nicht addieren."))
                    .font(.caption).foregroundStyle(ObservatoryAppearance.muted)
                Text(ui.text("Genauigkeit, eingesparte Zeit, GPU-Auslastung und Energie werden hier nicht gemessen."))
                    .font(.caption).foregroundStyle(ObservatoryAppearance.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { _ = model.refresh(qaDisabled: qaDisabled) }
        .onDisappear { model.leave() }
    }

    @ViewBuilder private var exportStatus: some View {
        switch exportController.state {
        case .idle: EmptyView()
        case .choosing: Text(ui.text("Exportziel wird gewählt …"))
        case .writing: ProgressView(ui.text("JSON-Bericht wird geschrieben …"))
        case .saved:
            Label(ui.text("Ein zuvor angezeigter Statistik-Schnappschuss wurde als JSON gespeichert."),
                  systemImage: "checkmark.circle")
        case .chooserCancelled:
            Text(ui.text("Export abgebrochen. Es wurde kein Ziel gewählt."))
        case .cancelledBeforeWrite:
            Text(ui.text("Export vor dem Schreiben abgebrochen."))
        case .anotherExportActive:
            Text(ui.text("Ein anderer Statistikexport läuft bereits. Bitte warte auf dessen Abschluss."))
        case .invalidSnapshot:
            Label(ui.text("Dieser Statistik-Schnappschuss konnte nicht sicher exportiert werden."),
                  systemImage: "exclamationmark.circle")
        case .invalidDestination:
            Label(ui.text("Nur eine bewusst gewählte JSON-Datei kann beschrieben werden."),
                  systemImage: "exclamationmark.circle")
        case .writeOutcomeUncertain:
            Label(ui.text("Speichern nicht bestätigt. Die angezeigte Statistik blieb unverändert; ob die Zieldatei geschrieben wurde, ist unklar."),
                  systemImage: "exclamationmark.circle")
        }
    }

    @ViewBuilder private func reportContent(_ result: LocalStatisticsLoadResult) -> some View {
        let hasMicrophone = hasRecordedActivity(result.report.microphone)
        let hasAudioFile = hasRecordedActivity(result.report.audioFile)
        let hasTranscriptFile = hasRecordedActivity(result.report.transcriptFile)
        if !result.hasEventsInPeriod {
            Text(ui.text("Für diesen Zeitraum wurden keine auswertbaren lokalen Einträge gefunden. Das belegt keine Nutzung von null."))
        }
        if hasMicrophone || hasAudioFile {
            transcriptionOverview(result.report.microphone, result.report.audioFile)
        }
        if hasMicrophone {
            sourceSection(result.report.microphone, title: ui.text("Mikrofon"),
                          showBottomRule: hasAudioFile || hasTranscriptFile)
        }
        if hasAudioFile {
            sourceSection(result.report.audioFile, title: ui.text("Audiodatei"),
                          showBottomRule: hasTranscriptFile)
        }
        if hasTranscriptFile {
            sourceSection(result.report.transcriptFile, title: ui.text("Transkriptdatei"),
                          showBottomRule: false)
        }
        if !isSyntheticPreview { snapshotFooter(result) }
    }

    /// Only the visual scale is derived here. Source values/sample counts and
    /// their existing aggregation, load and export contracts remain unchanged.
    private func transcriptionOverview(_ microphone: LocalStatisticsSummaryBuilder.Source,
                                       _ audioFile: LocalStatisticsSummaryBuilder.Source) -> some View {
        let microphoneWords = microphone.recognizedWordsOnCompleted
        let fileWords = audioFile.recognizedWordsOnCompleted
        let observedWords = [microphoneWords.sum, fileWords.sum].compactMap { $0 }
        let totalWords = observedWords.reduce(into: (value: 0, overflow: false)) { total, next in
            let addition = total.value.addingReportingOverflow(next)
            total = (addition.partialValue, total.overflow || addition.overflow)
        }
        let wordScale = LocalStatisticsPlotScale.words([microphoneWords.sum, fileWords.sum])
        let microphoneDecode = microphone.decodeServiceSecondsOnCompleted
        let fileDecode = audioFile.decodeServiceSecondsOnCompleted
        let decodeScale = LocalStatisticsPlotScale.elapsedSeconds([microphoneDecode.mean, fileDecode.mean])
        let wordTotal = totalWords.overflow ? ui.text("nicht verfügbar") :
            (observedWords.isEmpty ? ui.text("nicht gemessen") :
                plotText.count(totalWords.value, compact: true) ?? ui.text("nicht verfügbar"))
        let exactWordTotal = totalWords.overflow || observedWords.isEmpty ? nil : plotText.count(totalWords.value)
        let completedTotal = plotText.count(microphone.completed + audioFile.completed) ?? ui.text("nicht verfügbar")
        return VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 24) {
                    overviewValue(ui.text("Erkannte Wörter"), value: wordTotal, accessibleValue: exactWordTotal)
                    overviewValue(ui.text("Abgeschlossene Sitzungen"), value: completedTotal)
                }
                VStack(alignment: .leading, spacing: 6) {
                    overviewValue(ui.text("Erkannte Wörter"), value: wordTotal, accessibleValue: exactWordTotal)
                    overviewValue(ui.text("Abgeschlossene Sitzungen"), value: completedTotal)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ViewThatFits(in: .horizontal) {
                pairedComparisons(microphoneWords, fileWords,
                    microphoneDecode: microphoneDecode, fileDecode: fileDecode,
                    wordScale: wordScale, decodeScale: decodeScale)
                VStack(alignment: .leading, spacing: 14) {
                    wordComparison(microphoneWords, fileWords, scale: wordScale)
                    decodeComparison(microphoneDecode, fileDecode, scale: decodeScale)
                }
            }
            // Scale, exact values and accepted snapshot move together, without
            // an implicit animation through an obsolete numerical domain.
            .transaction { $0.animation = nil }
            Text(ui.text("Ältere Messpunkte können fehlen"))
                .font(.system(size: 11))
                .foregroundStyle(ObservatoryAppearance.muted)
                .help(ui.text("Die historische Abdeckung ist unbekannt: Aufzeichnung kann wegen Grenzen oder Fehlern fehlen. Starts und Ergebnisse werden nach ihren jeweiligen Zeitpunkten gezählt und müssen sich nicht addieren."))
        }
        .padding(.vertical, 10)
        .overlay(alignment: .top) { ObservatoryAppearance.rule.frame(height: 1) }
        .overlay(alignment: .bottom) { ObservatoryAppearance.rule.frame(height: 1) }
    }

    private func overviewValue(_ title: String, value: String, accessibleValue: String? = nil) -> some View {
        // One baseline and one nonwrapping text run: vertical scrolling cannot
        // remove a separate label row while leaving a large unlabeled value.
        (Text(title + "  ")
            .font(.system(size: 12))
            .foregroundColor(ObservatoryAppearance.muted) +
         Text(value)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundColor(ObservatoryAppearance.ink))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibleValue ?? value)
        .help(accessibleValue ?? value)
    }

    private func comparisonHeading(_ title: String, scale: LocalStatisticsPlotScale?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 12, weight: .medium))
            if let scale {
                Text(plotText.scaleLabel(scale))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(ObservatoryAppearance.muted)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func pairedComparisons(_ microphoneWords: LocalStatisticsSummaryBuilder.Words,
                                   _ fileWords: LocalStatisticsSummaryBuilder.Words,
                                   microphoneDecode: LocalStatisticsSummaryBuilder.MeasuredDouble,
                                   fileDecode: LocalStatisticsSummaryBuilder.MeasuredDouble,
                                   wordScale: LocalStatisticsPlotScale?,
                                   decodeScale: LocalStatisticsPlotScale?) -> some View {
        // Pair by source, not by independently stacked metric columns. Each row
        // takes its taller cell's natural height, including endpoints or unknown
        // counts, so the next source starts at the same height in both columns.
        VStack(alignment: .leading, spacing: 8) {
            LocalStatisticsComparisonPair {
                comparisonHeading(ui.text("Wörter nach Quelle"), scale: wordScale)
            } trailing: {
                comparisonHeading(ui.text("Mittlere Erkennungszeit"), scale: decodeScale)
                    .help(plotText.durationHelp)
            }
            LocalStatisticsComparisonPair {
                wordComparisonRow(ui.text("Mikrofon"), microphoneWords, scale: wordScale)
            } trailing: {
                decodeComparisonRow(ui.text("Mikrofon"), microphoneDecode, scale: decodeScale)
            }
            LocalStatisticsComparisonPair {
                wordComparisonRow(ui.text("Audiodatei"), fileWords, scale: wordScale)
            } trailing: {
                decodeComparisonRow(ui.text("Audiodatei"), fileDecode, scale: decodeScale)
            }
            LocalStatisticsComparisonPair {
                // Layout space only: the qualification belongs to elapsed time,
                // never to the word chart or the report-wide coverage notice.
                Color.clear.frame(height: 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            } trailing: {
                durationMeaning
            }
        }
    }

    private func wordComparison(_ microphone: LocalStatisticsSummaryBuilder.Words,
                                _ audioFile: LocalStatisticsSummaryBuilder.Words,
                                scale: LocalStatisticsPlotScale?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            comparisonHeading(ui.text("Wörter nach Quelle"), scale: scale)
            wordComparisonRow(ui.text("Mikrofon"), microphone, scale: scale)
            wordComparisonRow(ui.text("Audiodatei"), audioFile, scale: scale)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func wordComparisonRow(_ source: String, _ words: LocalStatisticsSummaryBuilder.Words,
                                   scale: LocalStatisticsPlotScale?) -> some View {
        comparisonRow(source,
            value: plotText.count(words.sum, compact: true),
            accessibleValue: plotText.count(words.sum).map { $0 + " " + plotTextWordUnit },
            proportion: scale?.proportion(for: words.sum.map { Double($0) }),
            observed: words.observed, unknown: words.unknown, isDuration: false)
    }

    private var plotTextWordUnit: String { LocalStatisticsPlotScale.Unit.words.symbol(english: ui == .english) }

    private func decodeComparison(_ microphone: LocalStatisticsSummaryBuilder.MeasuredDouble,
                                  _ audioFile: LocalStatisticsSummaryBuilder.MeasuredDouble,
                                  scale: LocalStatisticsPlotScale?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            comparisonHeading(ui.text("Mittlere Erkennungszeit"), scale: scale)
                .help(plotText.durationHelp)
            decodeComparisonRow(ui.text("Mikrofon"), microphone, scale: scale)
            decodeComparisonRow(ui.text("Audiodatei"), audioFile, scale: scale)
            durationMeaning
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func decodeComparisonRow(_ source: String,
                                     _ measurement: LocalStatisticsSummaryBuilder.MeasuredDouble,
                                     scale: LocalStatisticsPlotScale?) -> some View {
        comparisonRow(source, value: plotText.duration(measurement.mean, on: scale),
            proportion: scale?.proportion(for: measurement.mean),
            observed: measurement.observed, unknown: measurement.unknown, isDuration: true, scale: scale)
    }

    private var durationMeaning: some View {
        Text(plotText.durationMeaning)
            .font(.system(size: 11))
            .foregroundStyle(ObservatoryAppearance.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func comparisonRow(_ source: String, value: String?, accessibleValue: String? = nil,
                               proportion: Double?, observed: Int, unknown: Int,
                               isDuration: Bool, scale: LocalStatisticsPlotScale? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(source).foregroundStyle(ObservatoryAppearance.muted)
                Text("n = \(observed)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(ObservatoryAppearance.muted)
                    .help(plotText.samples(observed: observed, unknown: unknown, isDuration: isDuration))
                Spacer(minLength: 4)
                Text(value ?? ui.text("nicht gemessen"))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
            }
            .font(.system(size: 12))
            if let proportion, proportion.isFinite, value != nil {
                GeometryReader { geometry in
                    let width = max(0, geometry.size.width)
                    let fraction = min(max(0, proportion), 1)
                    ZStack(alignment: .leading) {
                        if isDuration {
                            // Endpoint ticks are the actual zero/common bound,
                            // not a draggable control or a quality/progress meter.
                            Rectangle().fill(ObservatoryAppearance.rule)
                                .frame(width: max(0, width - 4), height: 1)
                                .offset(x: 2)
                            Path { path in
                                for x in [CGFloat(2), max(2, width - 2)] {
                                    path.move(to: CGPoint(x: x, y: 1))
                                    path.addLine(to: CGPoint(x: x, y: 7))
                                }
                            }
                            .stroke(ObservatoryAppearance.muted, lineWidth: 1)
                            Circle().fill(ObservatoryAppearance.ink)
                                .frame(width: 4, height: 4)
                                .offset(x: max(0, width - 4) * fraction)
                        } else {
                            Rectangle().fill(ObservatoryAppearance.rule).frame(height: 3)
                            Rectangle().fill(ObservatoryAppearance.ink)
                                .frame(width: width * fraction, height: 3)
                        }
                    }
                    .frame(height: isDuration ? 8 : 6)
                }
                .frame(height: isDuration ? 8 : 6)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                if isDuration, let scale {
                    let endpoints = plotText.axisEndpoints(scale)
                    HStack {
                        Text(endpoints.lower)
                        Spacer(minLength: 8)
                        Text(endpoints.upper)
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(ObservatoryAppearance.muted)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true) // The section's scale label already reads both bounds.
                }
            }
            if unknown > 0 {
                Text("\(unknown) \(ui.text("unbekannt"))")
                    .font(.system(size: 11))
                    .foregroundStyle(ObservatoryAppearance.muted)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(source)
        .accessibilityValue((accessibleValue ?? value ?? ui.text("nicht gemessen")) + ", " +
            plotText.samples(observed: observed, unknown: unknown, isDuration: isDuration))
        .help((accessibleValue ?? value ?? ui.text("nicht gemessen")) + ", " +
            plotText.samples(observed: observed, unknown: unknown, isDuration: isDuration))
    }

    private func hasRecordedActivity(_ source: LocalStatisticsSummaryBuilder.Source) -> Bool {
        let reviews = source.reviews
        return source.started > 0 || source.completed > 0 || source.failed > 0 ||
            source.cancelled > 0 || source.interrupted > 0 ||
            source.incompleteAtPeriodEnd > 0 || source.ambiguous > 0 ||
            reviews.copy.attempts > 0 || reviews.save.attempts > 0 ||
            reviews.open.attempts > 0 || reviews.discard.attempts > 0 ||
            reviews.cancel.attempts > 0
    }

    private func sourceSection(_ source: LocalStatisticsSummaryBuilder.Source, title: String,
                               showBottomRule: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title).font(.system(size: 13, weight: .medium))
                Spacer(minLength: 4)
                if source.kind != .transcriptFile {
                    Text("\(ui.text("Starts")) \(source.started)  ·  \(ui.text("Abschlüsse")) \(source.completed)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(ObservatoryAppearance.muted)
                }
            }
            if source.kind != .transcriptFile {
                HStack(spacing: 8) {
                    Text(ui.text("WPM · Ø Sitzung"))
                        .font(.system(size: 11))
                        .foregroundStyle(ObservatoryAppearance.muted)
                    Text(source.audioWordRateOnCompleted.mean.map { String(format: "%.1f", $0) } ??
                         ui.text("nicht gemessen"))
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                }
                let warnings = warningSummary(source)
                if !warnings.isEmpty {
                    Text(warnings)
                        .font(.caption).foregroundStyle(ObservatoryAppearance.warning)
                }
            } else {
                reviewSummary(source.reviews)
            }
            DisclosureGroup(ui.text("Details")) {
                VStack(alignment: .leading, spacing: 5) {
                    if source.kind != .transcriptFile {
                        Text(ui.text("Erfasste Starts") + ": \(source.started)")
                        Text(ui.text("Erfasste Abschlüsse") + ": \(source.completed)")
                        Text(ui.text("Erfasste Fehlschläge") + ": \(source.failed)")
                        Text(ui.text("Erfasste Abbrüche") + ": \(source.cancelled)")
                        Text(ui.text("Erfasste Unterbrechungen") + ": \(source.interrupted)")
                        Text(ui.text("Starts ohne erfasstes Ergebnis bis Zeitraumende") + ": \(source.incompleteAtPeriodEnd)")
                        Text(ui.text("Mehrdeutige Sitzungen") + ": \(source.ambiguous)")
                        measuredWords(source.recognizedWordsOnCompleted)
                        measuredSeconds(source.audioSecondsOnCompleted,
                            title: ui.text("Summe erfasster Audiodauer abgeschlossener Sitzungen"), usesMean: false)
                        measuredSeconds(source.decodeServiceSecondsOnCompleted,
                            title: ui.text("Mittlere Dekodierdienst-Zeit mit Ergebnisauswertung"), usesMean: true)
                        measuredSeconds(source.endToEndSecondsOnCompleted,
                            title: ui.text("Mittlere Vorgangsdauer"), usesMean: true)
                        if source.kind == .audioFile {
                            measuredSeconds(source.filePreparationSecondsOnCompleted,
                                title: ui.text("Mittlere Dateivorbereitung"), usesMean: true)
                        } else {
                            measuredSeconds(source.captureToResultSecondsOnCompleted,
                                title: ui.text("Mittlere Zeit von Mikrofonschließung bis Ergebnis"), usesMean: true)
                        }
                        measuredRate(source.audioWordRateOnCompleted)
                        requestedLanguageRow(source.requestedLanguageOnCompleted)
                    }
                    reviewRow(ui.text("Kopieren"), source.reviews.copy)
                    reviewRow(ui.text("Speichern"), source.reviews.save)
                    reviewRow(ui.text("Öffnen"), source.reviews.open)
                    reviewRow(ui.text("Verwerfen"), source.reviews.discard)
                    reviewRow(ui.text("Abbrechen"), source.reviews.cancel)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
            }
            .font(.caption)
            .foregroundStyle(ObservatoryAppearance.muted)
            .accessibilityLabel(title + " · " + ui.text("Alle Messwerte und Aktionen"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            if showBottomRule { ObservatoryAppearance.rule.frame(height: 1) }
        }
    }

    private func metricTile(_ title: String, value: String?, observed: Int, unknown: Int,
                            meaning: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(ObservatoryAppearance.muted)
                .lineLimit(2)
            Text(value ?? ui.text("nicht gemessen"))
                .font(.system(size: 20, weight: .medium, design: .monospaced))
                .lineLimit(1).minimumScaleFactor(0.75)
            Text("\(observed) \(ui.text("beobachtet"))" +
                 (unknown > 0 ? " · \(unknown) \(ui.text("unbekannt"))" : ""))
                .font(.system(size: 10))
                .foregroundStyle(ObservatoryAppearance.muted)
                .lineLimit(1).minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(meaning)
        .accessibilityValue((value ?? ui.text("nicht gemessen")) +
            ", \(observed) \(ui.text("beobachtet")), \(unknown) \(ui.text("unbekannt"))")
    }

    private func warningSummary(_ source: LocalStatisticsSummaryBuilder.Source) -> String {
        var parts: [String] = []
        if source.failed > 0 { parts.append("\(source.failed) \(ui.text("Fehlschläge"))") }
        if source.cancelled > 0 { parts.append("\(source.cancelled) \(ui.text("Abbrüche"))") }
        if source.interrupted > 0 { parts.append("\(source.interrupted) \(ui.text("Unterbrechungen"))") }
        if source.incompleteAtPeriodEnd > 0 {
            parts.append("\(source.incompleteAtPeriodEnd) \(ui.text("Starts ohne erfasstes Ergebnis bis Zeitraumende"))")
        }
        if source.ambiguous > 0 { parts.append("\(source.ambiguous) \(ui.text("Mehrdeutige Sitzungen"))") }
        return parts.joined(separator: "  ·  ")
    }

    private func reviewSummary(_ reviews: LocalStatisticsSummaryBuilder.Reviews) -> some View {
        let attempts = reviews.copy.attempts + reviews.save.attempts + reviews.open.attempts +
            reviews.discard.attempts + reviews.cancel.attempts
        let succeeded = reviews.copy.succeeded + reviews.save.succeeded + reviews.open.succeeded +
            reviews.discard.succeeded + reviews.cancel.succeeded
        return Text("\(succeeded) / \(attempts) " + ui.text("erfasste erfolgreiche Aktionen / Versuche"))
            .font(.system(size: 13, weight: .medium, design: .monospaced))
            .foregroundStyle(ObservatoryAppearance.muted)
    }

    private func measuredWords(_ words: LocalStatisticsSummaryBuilder.Words) -> some View {
        Text(ui.text("Erkannte Wörter abgeschlossener Sitzungen") + ": " +
             (words.sum.map { String($0) } ?? ui.text("nicht gemessen")) +
             " (\(words.observed) \(ui.text("beobachtet")), \(words.unknown) \(ui.text("unbekannt")))")
    }

    private func measuredSeconds(_ measure: LocalStatisticsSummaryBuilder.MeasuredDouble,
                                 title: String, usesMean: Bool) -> some View {
        let value = usesMean ? measure.mean : measure.sum
        let formatted = value.map { String(format: "%.2f s", $0) } ?? ui.text("nicht gemessen")
        return Text(title + ": " + formatted +
                    " (\(measure.observed) \(ui.text("beobachtet")), \(measure.unknown) \(ui.text("unbekannt")))")
    }

    private func measuredRate(_ measure: LocalStatisticsSummaryBuilder.MeasuredDouble) -> some View {
        let value = measure.mean.map { String(format: "%.1f", $0) } ?? ui.text("nicht gemessen")
        return Text(ui.text("Arithmetisches Mittel der erfassten Sitzungsraten: Wörter pro Minute Gesamtaudio, Pausen eingeschlossen") +
                    ": " + value +
                    " (\(measure.observed) \(ui.text("beobachtet")), \(measure.unknown) \(ui.text("unbekannt")))")
    }

    private func reviewRow(_ title: String, _ counts: LocalStatisticsSummaryBuilder.ReviewCounts) -> some View {
        Text(title + ": \(counts.succeeded) / \(counts.attempts) " + ui.text("erfasste erfolgreiche Aktionen / Versuche"))
    }

    private func requestedLanguageRow(_ counts: LocalStatisticsSummaryBuilder.RequestedLanguageCounts) -> some View {
        let rawDetectionCount = counts.autoDetectedRawIDs.values.reduce(0, +)
        let german = ui.text(LanguageMode.de.title)
        let english = ui.text(LanguageMode.en.title)
        let unknown = ui.text("unbekannt")
        let requested = "\(ui.text("Angeforderte Sprache bei abgeschlossenen Sitzungen")): " +
            "Auto \(counts.auto), \(german) \(counts.german), \(english) \(counts.english), " +
            "\(unknown) \(counts.unknown)"
        let detected = "\(ui.text("Nur bei Auto: rohe Backend-Spracherkennungs-ID vorhanden")): " +
            "\(rawDetectionCount), \(unknown) \(counts.autoDetectionUnknown). " +
            ui.text("Rohe IDs sind keine Sprach- oder Genauigkeitsbewertung.")
        return VStack(alignment: .leading, spacing: 2) {
            Text(requested)
            Text(detected)
        }
    }

    private func snapshotFooter(_ result: LocalStatisticsLoadResult) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(ui.text("Zuletzt gelesen") + ": " + result.loadedAt.formatted(date: .abbreviated, time: .shortened))
            if model.selectedPeriod == .retained {
                Text(ui.text("Aufbewahrte Einträge bis (ausschließlich)") + ": " +
                     result.report.period.endExclusive.formatted(date: .abbreviated, time: .shortened))
            } else {
                Text(ui.text("Von (einschließlich)") + ": " +
                     result.report.period.start.formatted(date: .abbreviated, time: .shortened))
                Text(ui.text("Bis (ausschließlich)") + ": " +
                     result.report.period.endExclusive.formatted(date: .abbreviated, time: .shortened))
            }
            Text(ui.text("Die Zeiträume sind rollende Fenster bis zum Aktualisieren; „Alle aufbewahrten Einträge“ meint nur noch gespeicherte Daten."))
            Text(ui.text("Nicht erfolgreiche Aktionen können auch abgebrochene Dateidialoge enthalten."))
        }.font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private func diagnosticContent(_ result: LocalStatisticsLoadResult) -> some View {
        let diagnostics = result.diagnostics
        VStack(alignment: .leading, spacing: 3) {
            if diagnostics.skippedFiles > 0 {
                Text(ui.text("Nicht lesbare oder ausgelassene Journaldateien") + ": \(diagnostics.skippedFiles)")
            }
            if diagnostics.malformedRecords > 0 {
                Text(ui.text("Ungültige Journalzeilen") + ": \(diagnostics.malformedRecords)")
            }
            if diagnostics.tornTailFiles > 0 {
                Text(ui.text("Unvollständige Dateienden") + ": \(diagnostics.tornTailFiles)")
            }
            if diagnostics.concurrentChangeDetected {
                Text(ui.text("Journal änderte sich beim Lesen. Bitte erneut aktualisieren."))
            }
            if diagnostics.readerMarkedPartial && diagnostics.skippedFiles == 0 &&
               diagnostics.malformedRecords == 0 && diagnostics.tornTailFiles == 0 &&
               !diagnostics.concurrentChangeDetected {
                Text(ui.text("Einige Ereigniszuordnungen waren nicht sicher auswertbar."))
            }
            let report = result.report
            if report.duplicateEventRecords > 0 {
                Text(ui.text("Doppelte Ereignisdatensätze") + ": \(report.duplicateEventRecords)")
            }
            if report.conflictingEventIDGroups > 0 {
                Text(ui.text("Widersprüchliche Ereignis-ID-Gruppen") + ": \(report.conflictingEventIDGroups)")
            }
            if report.invalidTimestampEvents > 0 {
                Text(ui.text("Ereignisse mit ungültigem Zeitpunkt") + ": \(report.invalidTimestampEvents)")
            }
            if report.unsupportedSchemaEvents > 0 {
                Text(ui.text("Ereignisse mit unbekanntem Schema") + ": \(report.unsupportedSchemaEvents)")
            }
            if report.invalidRecordEvents > 0 {
                Text(ui.text("Ungültige Ereignisse") + ": \(report.invalidRecordEvents)")
            }
            if report.orphanTerminalSessions > 0 {
                Text(ui.text("Ergebnisse ohne zuordenbaren Start") + ": \(report.orphanTerminalSessions)")
            }
            if report.orphanReviewEvents > 0 {
                Text(ui.text("Review-Aktionen ohne zuordenbares Ergebnis") + ": \(report.orphanReviewEvents)")
            }
        }.font(.caption).foregroundStyle(.secondary)
    }
}

/// The wide plot's shared row; no fixed height or fake metric-axis padding.
/// The existing ViewThatFits fallback retains the denser narrow plot stacks.
struct LocalStatisticsComparisonPair<Leading: View, Trailing: View>: View {
    private let leading: Leading
    private let trailing: Trailing

    init(@ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            leading.frame(minWidth: 300, maxWidth: .infinity, alignment: .leading)
            trailing.frame(minWidth: 300, maxWidth: .infinity, alignment: .leading)
        }
    }
}

private extension LocalStatisticsPeriod {
    var titleKey: String {
        switch self {
        case .last24Hours: return "Letzte 24 Stunden"
        case .last7Days: return "Letzte 7 Tage"
        case .last30Days: return "Letzte 30 Tage"
        case .retained: return "Alle aufbewahrten Einträge"
        }
    }
}

private extension LocalStatisticsFailure {
    var messageKey: String {
        switch self {
        case .unavailable: return "Lokale Statistik ist zurzeit nicht verfügbar."
        case .unsafeFiles: return "Lokale Journaldateien haben die Sicherheitsprüfung nicht bestanden. Es wurden keine Werte angezeigt."
        case .readFailed: return "Lokale Statistik konnte nicht gelesen werden. Bitte später erneut aktualisieren."
        case .aggregationFailed: return "Lokale Statistik konnte nicht sicher ausgewertet werden. Es wurden keine Werte angezeigt."
        }
    }
}
