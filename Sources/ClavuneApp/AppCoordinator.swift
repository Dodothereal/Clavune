import AppKit
import AVFoundation
import Carbon
import ClavuneCore
import SwiftUI

@MainActor
final class AppCoordinator: ObservableObject {
    @Published private(set) var session = SessionMachine()
    @Published private(set) var operationPending = false
    @Published private(set) var closePending = false
    @Published private(set) var model: ModelCandidate?
    @Published private(set) var modelStatus = "Kein Modell importiert"
    @Published private(set) var message = "Mikrofon geschlossen"
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var level: Float = 0
    @Published var editedText = ""
    @Published var language: LanguageMode = .auto
    @Published var deviceUID = ""
    @Published var channel = 0
    @Published private(set) var devices: [AudioInputDevice] = []
    @Published private(set) var metrics: SessionMetrics?
    let policy: ResourcePolicy
    private let capture = CaptureService()
    private let inference = InferenceService()
    private var modelURL: URL?
    private var cancellation: DecodeCancellation?
    private var task: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var privacyTimer: Timer?
    private var hotkey: HotkeyService?
    private var panel: RecordingPanelController?
    private var startCompleted = false
    private var firstSamplePending = false
    private var quitRequested = false
    private var cancellationGeneration: UInt64 = 0
    @Published var hotkeyEnabled = false
    @Published var holdToTalk = true
    @Published private(set) var hotkeyStatus = "Globaler Hotkey ist aus"

    init(policy: ResourcePolicy) {
        self.policy = policy
        refreshDevices()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.cancel() }
            })
        }
    }
    var busy: Bool { operationPending || closePending || session.phase.isBusy }
    var canStart: Bool { !busy && model != nil }
    func attachPanel(_ panel: RecordingPanelController) { self.panel = panel }
    func refreshDevices() { devices = AudioDeviceRegistry.inputs() }

    func importModel() {
        guard !busy else { return }
        let picker = NSOpenPanel()
        picker.title = "Whisper-Modell bewusst importieren"
        picker.message = "Eine geprüfte Kopie wird im Clavune-Modellordner gespeichert. Kein Audio wird übertragen. Die Qualitätsprüfung dieser Kandidaten steht noch aus."
        picker.canChooseDirectories = false; picker.allowsMultipleSelection = false
        guard picker.runModal() == .OK, let selected = picker.url else { return }
        operationPending = true; modelStatus = "Modell wird lokal geprüft …"
        let generation = cancellationGeneration
        task = Task {
            defer { finishOperation() }
            do {
                let candidates = try ModelStore.candidates()
                let destination = try FileManager.default.url(for: .applicationSupportDirectory,
                    in: .userDomainMask, appropriateFor: nil, create: true)
                    .appendingPathComponent(ProductIdentity.modelDirectory, isDirectory: true)
                let importTask = Task.detached(priority: .utility) {
                    try ModelStore.importModel(selected, into: destination, candidates: candidates)
                }
                let installed = try await withTaskCancellationHandler {
                    try await importTask.value
                } onCancel: { importTask.cancel() }
                guard !Task.isCancelled, generation == cancellationGeneration else { return }
                await inference.unload()
                guard !Task.isCancelled, generation == cancellationGeneration else { return }
                model = installed.candidate; modelURL = installed.url
                modelStatus = installed.candidate.fileName + " — Hash geprüft, Qualität noch ungemessen"
                message = "Modell bereit. Mikrofon geschlossen."
            } catch {
                guard !Task.isCancelled, generation == cancellationGeneration else { return }
                modelStatus = "Import fehlgeschlagen"
                message = ((error as? DictationError) ?? .modelInvalid).localizedDescription
            }
        }
    }
    func start() {
        guard canStart, let model, let modelURL else { return }
        guard !IsSecureEventInputEnabled() else { message = "Secure Input ist aktiv. Aufnahme bleibt geschlossen."; return }
        let id: UUID
        do { id = try session.begin(); cancellation = try DecodeCancellation() }
        catch { message = DictationError.busy.localizedDescription; return }
        operationPending = true
        startCompleted = false; firstSamplePending = false
        editedText = ""; elapsed = 0; level = 0
        metrics = SessionMetrics(session: id, requestedStart: mach_absolute_time())
        message = "Mikrofon geschlossen; Modell und Berechtigung werden vorbereitet …"
        panel?.show()
        let selectedUID = deviceUID
        let selectedChannel = channel
        task = Task {
            defer { finishOperation() }
            do {
                let granted: Bool
                switch AVCaptureDevice.authorizationStatus(for: .audio) {
                case .authorized: granted = true
                case .notDetermined: granted = await AVCaptureDevice.requestAccess(for: .audio)
                default: granted = false
                }
                guard granted else { throw DictationError.permissionDenied }
                guard session.id == id, !Task.isCancelled else { throw DictationError.cancelled }
                let warm = try await inference.load(url: modelURL, candidate: model)
                guard session.id == id, !Task.isCancelled else { throw DictationError.cancelled }
                metrics?.modelWarm = warm.warm; metrics?.modelLoadSeconds = warm.seconds
                refreshDevices()
                let device: AudioInputDevice?
                if selectedUID.isEmpty { device = nil }
                else {
                    guard let found = devices.first(where: { $0.uid == selectedUID }) else { throw DictationError.audioUnavailable }
                    device = found
                }
                message = "Mikrofon wird gestartet; noch keine nutzbaren Samples bestätigt …"
                try await capture.start(session: id, deviceID: device?.id, channel: selectedChannel, policy: policy,
                    onFirstSample: { [weak self = self] in
                        Task { @MainActor in
                            guard let self, self.session.id == id, self.session.phase == .preparing else { return }
                            self.firstSamplePending = true
                            if self.startCompleted { self.session.recording(id); self.message = "Aufnahme läuft" }
                        }
                    },
                    onProgress: { [weak self = self] seconds, peak in
                        Task { @MainActor in
                            guard let self, self.session.id == id else { return }
                            self.elapsed = seconds; self.level = peak
                        }
                    },
                    onFailure: { [weak self = self] error in
                        Task { @MainActor in self?.failed(error, id: id) }
                    })
                guard session.id == id, !Task.isCancelled else {
                    await capture.cancel(session: id); throw DictationError.cancelled
                }
                startCompleted = true
                if firstSamplePending { session.recording(id); message = "Aufnahme läuft" }
                startPrivacyWatchdog()
            } catch {
                await capture.cancel(session: id)
                failed((error as? DictationError) ?? .audioUnavailable, id: id)
            }
        }
    }
    func stop() {
        guard let id = session.id else { return }
        if session.phase == .preparing { cancel(); return }
        guard session.stopping(id), let cancellation else { return }
        operationPending = true
        metrics?.requestedStop = mach_absolute_time()
        message = "Aufnahmeende wird abgegrenzt …"
        let mode = language
        task = Task {
            defer { finishOperation(); stopPrivacyWatchdog() }
            do {
                let audio = try await capture.stop(session: id)
                guard session.id == id, !Task.isCancelled else { throw DictationError.cancelled }
                metrics?.firstSample = audio.firstHostTime; metrics?.requestedStop = audio.stopHostTime
                metrics?.captureClosed = audio.closedHostTime; metrics?.sourceSampleRate = audio.nativeRate
                metrics?.frames16k = audio.pcm.samples.count
                session.transcribing(id)
                level = 0; message = "Mikrofon geschlossen. Lokale Transkription läuft …"
                let result = try await inference.transcribe(audio.pcm, language: mode,
                    cancellation: cancellation, policy: policy)
                guard session.id == id, !Task.isCancelled else { throw DictationError.cancelled }
                metrics?.finalText = mach_absolute_time(); metrics?.decodeSeconds = result.decodeSeconds
                session.result(result.text, session: id)
                editedText = result.text
                message = result.text.isEmpty ? "Kein Text erkannt. Mikrofon geschlossen." : "Text bereit zum Prüfen. Mikrofon geschlossen."
                self.cancellation = nil
            } catch { failed((error as? DictationError) ?? .inferenceFailed, id: id) }
        }
    }
    func cancel() {
        guard !closePending else { return }
        let id = session.id
        guard busy || !editedText.isEmpty else { return }
        cancellationGeneration &+= 1
        let generation = cancellationGeneration
        closePending = true
        cancellation?.cancel(); task?.cancel()
        session.cancel(); editedText = ""; level = 0
        message = "Abbruch angefordert; Aufnahme wird geschlossen …"
        stopPrivacyWatchdog()
        Task {
            await capture.cancel(session: id)
            guard generation == cancellationGeneration else { return }
            closePending = false
            if session.phase == .cancelled, session.id == nil {
                message = operationPending ? "Mikrofon geschlossen; Abbruch der laufenden Arbeit wird abgewartet …" : "Abgebrochen. Mikrofon geschlossen."
            }
        }
    }
    private func finishOperation() {
        operationPending = false; task = nil
        if session.phase == .cancelled, !closePending {
            message = "Abgebrochen. Mikrofon geschlossen."
        }
    }
    private func failed(_ error: DictationError, id: UUID) {
        guard session.id == id, session.phase.isBusy else { return }
        session.fail(error, session: id); cancellation = nil; level = 0
        message = error.localizedDescription; stopPrivacyWatchdog()
    }
    func discard() {
        guard !busy else { return }
        session.discard(); editedText = ""; metrics = nil
        message = "Verworfen. Mikrofon geschlossen."; panel?.hide()
    }
    func copy() {
        guard session.phase == .review, !editedText.isEmpty else { return }
        let board = NSPasteboard.general
        board.prepareForNewContents(with: [.currentHostOnly])
        if board.setString(editedText, forType: .string) {
            message = "Bewusst kopiert. Die Zwischenablage ist für andere lokale Apps lesbar."
        } else { message = "Kopieren fehlgeschlagen. Text bleibt in der Vorschau." }
    }
    func unload() {
        guard !busy else { return }
        operationPending = true
        Task {
            await inference.unload()
            operationPending = false; message = "Modell aus dem Arbeitsspeicher entladen."
        }
    }
    func configureHotkey() {
        hotkey?.unregister(); hotkey = nil
        guard hotkeyEnabled else { hotkeyStatus = "Globaler Hotkey ist aus"; return }
        do {
            hotkey = try HotkeyService { [weak self] down in
                guard let self else { return }
                if IsSecureEventInputEnabled() { self.cancel(); return }
                if self.holdToTalk {
                    if down { self.start() } else { self.stop() }
                } else if down {
                    if self.session.phase == .recording { self.stop() } else { self.start() }
                }
            }
            hotkeyStatus = "Ctrl–Option–Leertaste registriert"
        } catch {
            hotkeyEnabled = false; hotkeyStatus = "Hotkey-Konflikt oder Registrierung fehlgeschlagen"
        }
    }
    private func startPrivacyWatchdog() {
        stopPrivacyWatchdog()
        privacyTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.session.phase.isBusy else { return }
                if IsSecureEventInputEnabled() || AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                    self.cancel()
                }
            }
        }
    }
    private func stopPrivacyWatchdog() { privacyTimer?.invalidate(); privacyTimer = nil }
    func quit() {
        guard !quitRequested else { return }
        quitRequested = true
        cancel(); hotkey?.unregister()
        Task { await capture.cancel(session: nil); await inference.unload(); NSApp.terminate(nil) }
    }
}
