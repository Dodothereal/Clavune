import AppKit
import ClavuneCore
import Combine
import Foundation
import UniformTypeIdentifiers

/// Isolated export boundary: only an explicit Statistics action invokes the
/// chooser, and only its selected URL receives a fixed-schema aggregate JSON.
/// It never records a transcript Review Save metric or changes coordinator state.
struct LocalStatisticsExportEnvironment {
    var chooseDestination: @MainActor (UILanguage, String) -> URL?
    var writeJSON: @Sendable (String, URL) throws -> Void

    static let production = LocalStatisticsExportEnvironment(
        chooseDestination: { ui, suggestedName in
            let panel = NSSavePanel()
            panel.title = ui.text("Statistikbericht als JSON speichern …")
            panel.message = ui.text("Nur aggregierte Messwerte. Der gewählte Ordner kann synchronisiert werden; der Bericht kann sensible Nutzungszeiten enthalten.")
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = suggestedName
            panel.canCreateDirectories = true
            // The standard Save panel obtains the user's explicit overwrite
            // decision. No path is selected or written without its OK response.
            return panel.runModal() == .OK ? panel.url : nil
        },
        // Reuse the existing bounded, exclusive-0600 staging + atomic-rename
        // UTF-8 writer. JSON stays under 64 KiB, well within its 4 MiB cap.
        writeJSON: { try TranscriptFileStore.write($0, to: $1) })
}

@MainActor
final class LocalStatisticsExportController: ObservableObject {
    enum State: Equatable {
        case idle, choosing, writing, saved
        case chooserCancelled, cancelledBeforeWrite, anotherExportActive
        case invalidSnapshot, invalidDestination, writeOutcomeUncertain
        var isBusy: Bool {
            switch self {
            case .choosing, .writing: return true
            default: return false
            }
        }
    }

    @Published private(set) var state: State = .idle
    private let environment: LocalStatisticsExportEnvironment
    private let gate: LocalStatisticsExportGate

    init(environment: LocalStatisticsExportEnvironment = .production,
         gate: LocalStatisticsExportGate? = nil) {
        self.environment = environment
        self.gate = gate ?? .shared
    }

    func export(_ input: LocalStatisticsJSONExport.Input, ui: UILanguage,
                generatedAt: Date = Date()) async {
        guard !state.isBusy else { return }
        let json: String
        do { json = try LocalStatisticsJSONExport.encode(input, generatedAt: generatedAt) }
        catch { state = .invalidSnapshot; return }

        guard !Task.isCancelled else { state = .cancelledBeforeWrite; return }
        guard let admission = gate.reserve() else {
            state = gate.isClosingForQuit ? .cancelledBeforeWrite : .anotherExportActive
            return
        }
        defer { gate.finish(admission) }
        state = .choosing
        let chosen = environment.chooseDestination(ui, "Clavune-Statistics.json")
        // A synchronous Save panel may outlive cancellation of its caller.
        // Never launch detached disk work from a cancelled panel response.
        guard !Task.isCancelled, gate.permitsWriting(admission) else {
            state = .cancelledBeforeWrite; return
        }
        guard let destination = chosen else { state = .chooserCancelled; return }
        guard destination.isFileURL,
              destination.pathExtension.lowercased() == "json" else {
            state = .invalidDestination
            return
        }
        guard !Task.isCancelled, gate.permitsWriting(admission) else {
            state = .cancelledBeforeWrite; return
        }
        let writer = environment.writeJSON
        guard let work = gate.startWriter(admission, write: { try writer(json, destination) }) else {
            state = .cancelledBeforeWrite; return
        }
        state = .writing
        let writeResult = await withTaskCancellationHandler(operation: {
            // Wait for the detached writer's terminal result even if this
            // caller was cancelled. Only then may `defer` release admission;
            // Quit must never see idle while a staging file is still owned.
            await work.result
        }, onCancel: { work.cancel() })
        // Publication below may synchronously trigger a new deliberate export
        // in another mounted host. The exact worker is already terminal here.
        gate.finish(admission)
        switch writeResult {
        case .success:
            // The writer has returned after an atomic commit. No status is
            // inferred from merely choosing a destination.
            state = .saved
        case .failure:
            // If cancellation/error raced the rename, the caller cannot prove
            // whether the chosen destination was changed. Never say "no file".
            state = .writeOutcomeUncertain
        }
    }
}
