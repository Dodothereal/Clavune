import AppKit
import AVFoundation
import Carbon
import ClavuneCore
import UniformTypeIdentifiers

enum UnsavedReviewQuitChoice: Equatable, Sendable {
    case save, discard, cancel
}

/// Shared native transcript panels and alerts. QA can constrain the initial
/// directory and reject any URL outside its private fixture root after dismissal.
@MainActor
enum NativeTranscriptDialogs {
    static func chooseOpen(ui: UILanguage, root: URL? = nil,
                           accepts: @MainActor (URL) -> Bool = { _ in true }) -> URL? {
        let picker = NSOpenPanel()
        picker.title = ui.text("Transkript öffnen …")
        picker.message = ui.text("UTF-8-Klartext, höchstens 4 MiB. Kein Audioimport.")
        picker.allowedContentTypes = [.plainText]
        picker.canChooseDirectories = false; picker.allowsMultipleSelection = false
        if let root {
            picker.directoryURL = root
            picker.nameFieldStringValue = "opened.txt"
        }
        guard picker.runModal() == .OK, let url = picker.url, accepts(url) else { return nil }
        return url
    }

    static func chooseSave(ui: UILanguage, root: URL? = nil,
                           accepts: @MainActor (URL) -> Bool = { _ in true }) -> URL? {
        let picker = NSSavePanel()
        picker.title = ui.text("Transkript speichern …")
        picker.message = ui.text("Speichert nur den bearbeiteten Text. Der gewählte Ordner kann synchronisiert werden.")
        picker.allowedContentTypes = [.plainText]
        picker.nameFieldStringValue = root == nil ? "Transcript.txt" : "saved.txt"
        picker.canCreateDirectories = root == nil
        if let root { picker.directoryURL = root }
        guard picker.runModal() == .OK, let url = picker.url, accepts(url) else { return nil }
        return url
    }

    static func confirmReplacement(ui: UILanguage) -> Bool {
        let alert = NSAlert()
        alert.messageText = ui.text("Aktuelle Vorschau ersetzen?")
        alert.informativeText = ui.text("Nicht gespeicherte Änderungen gehen verloren. Abbrechen behält die aktuelle Vorschau.")
        alert.addButton(withTitle: ui.text("Abbrechen"))
        alert.addButton(withTitle: ui.text("Vorschau ersetzen"))
        return alert.runModal() == .alertSecondButtonReturn
    }

    static func confirmQuit(ui: UILanguage) -> UnsavedReviewQuitChoice {
        let alert = NSAlert()
        alert.messageText = ui.text("Ungespeicherte Vorschau vor dem Beenden speichern?")
        alert.informativeText = ui.text("Die aktuelle Vorschau ist noch nicht gespeichert. Speichern schreibt den bearbeiteten Text in eine bewusst gewählte Datei.")
        alert.addButton(withTitle: ui.text("Abbrechen"))
        alert.addButton(withTitle: ui.text("Speichern …"))
        alert.addButton(withTitle: ui.text("Verwerfen und beenden"))
        switch alert.runModal() {
        case .alertSecondButtonReturn: return .save
        case .alertThirdButtonReturn: return .discard
        default: return .cancel
        }
    }
}

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
    var registerHotkey: @MainActor (DevelopmentShortcut, @escaping (Bool) -> Void) throws -> any HotkeyRegistration
    // Synchronous MainActor observations only; neither may suspend or drive shutdown.
    var quitWillAwaitAdmittedOperation: @MainActor () -> Void
    var quitWillUnloadInference: @MainActor () -> Void
    // Synchronously revoke Statistics export admission before Quit's first
    // suspension. A detached writer admitted before this cut is joined before
    // termination; a still-open chooser has no write admission and its late URL
    // is rejected by the shared gate. Synthetic environments default to no-op.
    var closeStatisticsExportsForQuit: @MainActor () -> Task<Void, Error>? = { nil }
    var statisticsExportActive: @MainActor () -> Bool = { false }
    var beginStatisticsExportQuitSave: @MainActor () -> Bool = { false }
    var waitForStatisticsExportIdle: @MainActor () async -> Void = {}
    var finishStatisticsExportQuitSave: @MainActor () -> Void = {}
    // One MainActor task per producer callback. Tests may retain that exact task;
    // dispatch does not own freshness policy or change the producer's cadence.
    var dispatchCaptureProgress: @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void = { work in
        _ = Task { @MainActor in work() }
    }

    // Lifecycle callbacks use the same one-task delivery, with an independent
    // test handle so a stale completion can be awaited, not guessed via FIFO.
    var dispatchCaptureLifecycle: @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void = { work in
        _ = Task { @MainActor in work() }
    }

    // Synthetic environments fail closed unless they inject an explicit sink.
    // Only .live below selects the deliberate general-clipboard boundary.
    var copyText: @MainActor (String) -> Bool = { _ in false }

    // Synchronous, Sendable file boundary; the coordinator always runs it detached.
    // Synthetic environments must opt in; never fall through to production storage.
    var restoreManagedSelection: @Sendable (String) throws -> ModelStore.Installed = { _ in
        throw DictationError.modelInvalid
    }

    // The coordinator runs this bounded copy/hash boundary detached. Synthetic
    // environments fail closed, never writing the production model directory.
    var importManagedModel: @Sendable (URL) throws -> ModelStore.Installed = { _ in
        throw DictationError.modelInvalid
    }

    // A download is an explicit user action. The callback reports byte progress;
    // audio, transcripts and diagnostics are never passed to this boundary.
    var downloadManagedModel: @Sendable (ModelCandidate, @escaping @Sendable (Int64) -> Void) async throws -> ModelStore.Installed = { _, _ in
        throw ModelDownloadFailure.unavailableSource
    }

    // Explicit document actions fail closed in synthetic environments.
    var chooseTranscriptToOpen: @MainActor (UILanguage) -> URL? = { _ in nil }
    var chooseTranscriptToSave: @MainActor (UILanguage) -> URL? = { _ in nil }
    var confirmTranscriptReplacement: @MainActor (UILanguage) -> Bool = { _ in false }
    var readTranscript: @Sendable (URL) throws -> String = { _ in throw TranscriptFileStore.Failure.invalidFile }
    var writeTranscript: @Sendable (String, URL) throws -> Void = { _, _ in throw TranscriptFileStore.Failure.invalidFile }
    var confirmUnsavedReviewQuit: @MainActor (UILanguage) -> UnsavedReviewQuitChoice = { _ in .cancel }

    var chooseAudioToImport: @MainActor (UILanguage) -> URL? = { _ in nil }
    var readAudio: @Sendable (URL, ResourcePolicy) throws -> SessionPCM = { _, _ in
        throw AudioFileImporter.Failure.invalidFile
    }

    static func live(preferences: AppPreferences) -> Self {
        Self(nowHostTime: { mach_absolute_time() }, secureInputEnabled: { IsSecureEventInputEnabled() },
             permissionStatus: { AVCaptureDevice.authorizationStatus(for: .audio) },
             requestPermission: { await AVCaptureDevice.requestAccess(for: .audio) },
             inputDevices: { AudioDeviceRegistry.inputs() }, chooseModel: {
                 let picker = NSOpenPanel()
                 let ui = UILanguage(rawValue: preferences.string(forKey: "uiLanguage") ?? "") ?? .english
                 picker.title = ui.text("Whisper-Modell bewusst importieren")
                 picker.message = ui.text("Eine geprüfte Kopie wird im Clavune-Modellordner gespeichert. Kein Audio wird übertragen. Die Qualitätsprüfung dieser Kandidaten steht noch aus.")
                 picker.canChooseDirectories = false; picker.allowsMultipleSelection = false
                 return picker.runModal() == .OK ? picker.url : nil
             }, makeCancellation: { try DecodeCancellation() }, makeWatchdog: { action in
                 let timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
                     Task { @MainActor in action() }
                 }
                 return { timer.invalidate() }
             }, workspaceNotifications: NSWorkspace.shared.notificationCenter,
             terminate: { NSApp.terminate(nil) },
             registerHotkey: { try HotkeyService(shortcut: $0, action: $1) },
             quitWillAwaitAdmittedOperation: {}, quitWillUnloadInference: {},
             closeStatisticsExportsForQuit: { LocalStatisticsExportGate.shared.closeForQuit() },
             statisticsExportActive: { LocalStatisticsExportGate.shared.isActive },
             beginStatisticsExportQuitSave: { LocalStatisticsExportGate.shared.beginQuitSave() },
             waitForStatisticsExportIdle: { await LocalStatisticsExportGate.shared.waitUntilIdle() },
             finishStatisticsExportQuitSave: { LocalStatisticsExportGate.shared.finishQuitSave() },
             copyText: { LocalClipboard.copy($0) }, restoreManagedSelection: { hash in
                 let directory = try FileManager.default.url(for: .applicationSupportDirectory,
                     in: .userDomainMask, appropriateFor: nil, create: false)
                     .appendingPathComponent(ProductIdentity.modelDirectory, isDirectory: true)
                 return try ModelStore.restoreSelection(hash, in: directory, candidates: ModelStore.candidates())
             }, importManagedModel: { selected in
                 let candidates = try ModelStore.candidates()
                 let destination = try FileManager.default.url(for: .applicationSupportDirectory,
                     in: .userDomainMask, appropriateFor: nil, create: true)
                     .appendingPathComponent(ProductIdentity.modelDirectory, isDirectory: true)
                 return try ModelStore.importModel(selected, into: destination, candidates: candidates)
             }, downloadManagedModel: { candidate, progress in
                let destination = try FileManager.default.url(for: .applicationSupportDirectory,
                    in: .userDomainMask, appropriateFor: nil, create: true)
                    .appendingPathComponent(ProductIdentity.modelDirectory, isDirectory: true)
                return try await ModelDownloadService.download(candidate, into: destination, progress: progress)
             }, chooseTranscriptToOpen: { ui in NativeTranscriptDialogs.chooseOpen(ui: ui) },
             chooseTranscriptToSave: { ui in NativeTranscriptDialogs.chooseSave(ui: ui) },
             confirmTranscriptReplacement: { ui in NativeTranscriptDialogs.confirmReplacement(ui: ui) },
             readTranscript: { try TranscriptFileStore.read($0) },
             writeTranscript: { try TranscriptFileStore.write($0, to: $1) },
             confirmUnsavedReviewQuit: { ui in NativeTranscriptDialogs.confirmQuit(ui: ui) },
             chooseAudioToImport: { ui in
                 let picker = NSOpenPanel()
                 picker.title = ui.text("Audiodatei importieren …")
                 picker.message = ui.text("M4A (AAC-LC/ALAC), AAC-LC, MP3 oder PCM-WAV; Mono/Stereo, höchstens 120 s und 64 MiB. Stereo wird als Mittel beider Kanäle verarbeitet. Keine Audiokopie.")
                 picker.allowedContentTypes = [.mpeg4Audio, .mp3, .wav] +
                     [UTType(filenameExtension: "aac")].compactMap { $0 }
                 picker.canChooseDirectories = false; picker.allowsMultipleSelection = false
                 return picker.runModal() == .OK ? picker.url : nil
             }, readAudio: { try AudioFileImporter.read($0, policy: $1) })
    }
}
