import ClavuneCore
import SwiftUI

/// Manifest-backed guidance; downloading starts only from the explicit button action.
struct ModelImportGuidance: View {
    let catalogue: ModelCatalogue?
    let ui: UILanguage
    let selectedModelSHA256: String?
    let verifiedInstalledModelHashes: Set<String>
    let localModelInventoryChecked: Bool
    let isBusy: Bool
    let isSetup: Bool
    let allowsDownload: Bool
    let allowsTextSelection: Bool
    let onDownload: (ModelCandidate) -> Void
    let onCheckInstalled: () -> Void
    let onSelectInstalled: (ModelCandidate) -> Void
    @State private var expanded: Bool

    init(catalogue: ModelCatalogue?, ui: UILanguage, selectedModelSHA256: String?,
         verifiedInstalledModelHashes: Set<String>, localModelInventoryChecked: Bool,
         isBusy: Bool, onDownload: @escaping (ModelCandidate) -> Void,
         onCheckInstalled: @escaping () -> Void, onSelectInstalled: @escaping (ModelCandidate) -> Void,
         isSetup: Bool = false, allowsDownload: Bool = true, allowsTextSelection: Bool = true) {
        self.catalogue = catalogue
        self.ui = ui
        self.selectedModelSHA256 = selectedModelSHA256
        self.verifiedInstalledModelHashes = verifiedInstalledModelHashes
        self.localModelInventoryChecked = localModelInventoryChecked
        self.isBusy = isBusy
        self.onDownload = onDownload
        self.onCheckInstalled = onCheckInstalled
        self.onSelectInstalled = onSelectInstalled
        self.isSetup = isSetup
        self.allowsDownload = allowsDownload
        self.allowsTextSelection = allowsTextSelection
        _expanded = State(initialValue: isSetup)
    }

    @ViewBuilder private func selectableText(_ value: String) -> some View {
        if allowsTextSelection {
            Text(value).textSelection(.enabled)
        } else {
            Text(value).textSelection(.disabled)
        }
    }

    var body: some View {
        DisclosureGroup(ui.text(isSetup ? "Modelle auswählen oder herunterladen" : "Akzeptierte Modellkandidaten"),
                        isExpanded: $expanded) {
            if let catalogue {
                Button(ui.text("Lokale Modelle prüfen (kein Download)"), action: onCheckInstalled)
                    .disabled(isBusy || !allowsDownload)
                Text(ui.text("Die Prüfung liest nur verwaltete Modelldateien und vergleicht Größe und SHA-256. Sie kann bei großen Dateien dauern. Sie wählt kein Modell aus."))
                    .font(.caption)
                ForEach(catalogue.models) { candidate in
                    let isSelected = selectedModelSHA256 == candidate.sha256
                    let isVerified = verifiedInstalledModelHashes.contains(candidate.sha256)
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            selectableText(candidate.fileName)
                            let humanSize = ByteCountFormatter.string(fromByteCount: candidate.sizeBytes, countStyle: .file)
                            Text(String(format: ui.text("Dateigröße: %@ (%lld Bytes)"), humanSize, candidate.sizeBytes))
                                .font(.caption)
                            Text(String(format: ui.text("Lizenz: %@ · %@"), candidate.license, ui.modelRole(candidate.role)))
                                .font(.caption)
                            if candidate.downloadEnabled, let source = candidate.sourceURL, let revision = candidate.sourceRevision {
                                selectableText(String(format: ui.text("Quelle: %@ · Revision %@"), source.host ?? "unknown", revision))
                                    .font(.caption)
                            }
                            Text(ui.text(isSelected && isVerified ? "Ausgewählt und lokal geprüft" :
                                isSelected && localModelInventoryChecked ? "Ausgewählt; lokale Datei ungültig oder nicht verfügbar" :
                                isSelected ? "Ausgewählt; lokaler Status nicht geprüft" :
                                isVerified ? "Lokal geprüft; bei Auswahl erneut geprüft" :
                                localModelInventoryChecked ? "Keine geprüfte lokale Kopie" : "Lokaler Status nicht geprüft"))
                                .font(.caption)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        if isSelected {
                            if localModelInventoryChecked && !isVerified && candidate.downloadEnabled {
                                Button(ui.text("Herunterladen und prüfen")) { onDownload(candidate) }
                                    .disabled(isBusy || !allowsDownload)
                            } else {
                                Button(ui.text(isVerified ? "Bereit" :
                                    localModelInventoryChecked ? "Lokal nicht bereit" : "Nicht geprüft")) {}.disabled(true)
                            }
                        } else if isVerified {
                            Button(ui.text("Lokal auswählen (kein Download)")) { onSelectInstalled(candidate) }
                                .disabled(isBusy || !allowsDownload)
                        } else if candidate.downloadEnabled {
                            Button(ui.text("Herunterladen und prüfen")) { onDownload(candidate) }
                                .disabled(isBusy || !allowsDownload)
                        }
                    }
                }
                Text(ui.text("Nur exakt passende Dateigröße und SHA-256-Inhalte werden akzeptiert. Kein automatischer Download und kein empfohlenes Standardmodell."))
                    .font(.caption)
                Text(ui.text("Ein Download startet nur nach deiner Auswahl. Es werden ausschließlich Modelldaten vom fest gepinnten Hugging-Face-Quellstand über festgelegte HTTPS-Downloadserver geladen; Spracheingaben und Transkripte werden nicht übertragen. Abgebrochene Downloads können fortgesetzt werden."))
                    .font(.caption)
                Text(ui.text("Die lokale Auswahl prüft die Datei erneut und startet nie einen Download. Die Download-Aktion nutzt eine bereits gültige lokale Kopie, kann sonst aber eine Netzwerkübertragung starten."))
                    .font(.caption)
                if !catalogue.releaseApproved {
                    Text(ui.text("Noch keine Release-Freigabe. Qualität, Konvertierungsherkunft und allgemeine Engine-Kompatibilität dieser Kandidaten sind nicht abschließend validiert."))
                        .font(.caption)
                }
                Text(ui.text("Bei ungültiger gespeicherter Datei bewusst erneut importieren. Vorhandene Sicherungen werden erhalten; eine blockierte Wiederherstellung wird erklärt und nicht automatisch überschrieben."))
                    .font(.caption)
            } else {
                Text(ui.text("Modellliste nicht verfügbar. Kein ungeprüftes Modell wird ausgewählt."))
            }
        }
    }
}
