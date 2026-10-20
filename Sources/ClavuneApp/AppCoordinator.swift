import AppKit
import AVFoundation
import Carbon
import ClavuneCore
import SwiftUI

@MainActor
final class AppCoordinator: ObservableObject {
    @Published private(set) var session = SessionMachine()
    @Published private(set) var microphone = MicrophoneLifecycle()
    @Published private(set) var operationPending = false
    @Published private(set) var closePending = false
    @Published private var importAdmission = OperationAdmission()
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
    private let capture: any CaptureServicing
    private let inference: any InferenceServicing
    private let environment: CoordinatorEnvironment
    private var modelURL: URL?
    private var cancellation: DecodeCancellation?
    private var startupGate: CaptureStartupGate?
    private var task: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var cancelPrivacyWatchdog: (() -> Void)?
    private var operationNeedsDrain = false
    private var hotkey: HotkeyService?
    private var panel: RecordingPanelController?
    private var startCompleted = false
    private var firstSamplePending = false
    private var quitRequested = false
    private var cancellationGeneration: UInt64 = 0
    @Published var hotkeyEnabled = false
    @Published var holdToTalk = true
    @Published var developmentShortcut: DevelopmentShortcut = .controlShiftSpace
    @Published private(set) var hotkeyStatus = "Globaler Hotkey ist aus"

    convenience init(policy: ResourcePolicy) {
        self.init(policy: policy, capture: CaptureService(), inference: InferenceService(), environment: .live)
    }
    init(policy: ResourcePolicy, capture: any CaptureServicing, inference: any InferenceServicing,
         environment: CoordinatorEnvironment, modelSelection: (candidate: ModelCandidate, url: URL)? = nil) {
        self.policy = policy; self.capture = capture; self.inference = inference; self.environment = environment
        model = modelSelection?.candidate; modelURL = modelSelection?.url
        refreshDevices()
        if let center = environment.workspaceNotifications {
            for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.cancel() }
                })
            }
        }
    }
    var busy: Bool { quitRequested || operationPending || closePending || importAdmission.isHeld || session.phase.isBusy }
    var canStart: Bool { !busy && model != nil }
    func attachPanel(_ panel: RecordingPanelController) { self.panel = panel }
    func refreshDevices() { devices = environment.inputDevices() }

    func importModel() {
        guard !busy, let admission = importAdmission.begin() else { return }
        let generation = cancellationGeneration
        guard let selected = environment.chooseModel(),
              importAdmission.permits(admission), generation == cancellationGeneration,
              !closePending, !session.phase.isBusy else {
            importAdmission.finish(admission); return
        }
        operationPending = true; operationNeedsDrain = true; modelStatus = "Modell wird lokal geprüft …"
        task = Task {
            defer {
                if Task.isCancelled || generation != cancellationGeneration {
                    modelStatus = model == nil ? "Import abgebrochen; kein Modell ausgewählt" : "Import abgebrochen; bisheriges Modell ausgewählt"
                }
                importAdmission.finish(admission); finishOperation()
            }
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
                if let recovery = error as? ModelStore.RecoveryError {
                    message = recovery.localizedDescription
                } else { message = ((error as? DictationError) ?? .modelInvalid).localizedDescription }
            }
        }
    }
    func start() {
        guard canStart, let model, let modelURL else { return }
        guard !environment.secureInputEnabled() else { message = "Secure Input ist aktiv. Aufnahme bleibt geschlossen."; return }
        let id: UUID
        do {
            let admitted = try session.begin(preparing: environment.makeCancellation)
            id = admitted.id; cancellation = admitted.resource
        }
        catch {
            let failure = (error as? DictationError) ?? .inferenceFailed
            message = failure.localizedDescription
            return
        }
        operationPending = true; operationNeedsDrain = false
        let authorization = CaptureStartupGate()
        startupGate = authorization
        startCompleted = false; firstSamplePending = false
        editedText = ""; elapsed = 0; level = 0
        metrics = SessionMetrics(session: id, requestedStart: environment.nowHostTime())
        message = "Mikrofon geschlossen; Modell und Berechtigung werden vorbereitet …"
        panel?.show()
        let selectedUID = deviceUID
        let selectedChannel = channel
        startPrivacyWatchdog()
        task = Task {
            defer { finishOperation() }
            do {
                guard session.id == id, session.phase == .preparing, !quitRequested, !Task.isCancelled else {
                    throw DictationError.cancelled
                }
                let granted: Bool
                switch environment.permissionStatus() {
                case .authorized: granted = true
                case .notDetermined: granted = await environment.requestPermission()
                default: granted = false
                }
                guard granted else { throw DictationError.permissionDenied }
                guard session.id == id, session.phase == .preparing, !quitRequested, !Task.isCancelled else { throw DictationError.cancelled }
                operationNeedsDrain = true // Permission waiting above owns no capture/model resource.
                let warm = try await inference.load(url: modelURL, candidate: model)
                guard session.id == id, !quitRequested, !Task.isCancelled else { throw DictationError.cancelled }
                metrics?.modelWarm = warm.warm; metrics?.modelLoadSeconds = warm.seconds
                refreshDevices()
                let device: AudioInputDevice?
                if selectedUID.isEmpty { device = nil }
                else {
                    guard let found = devices.first(where: { $0.uid == selectedUID }) else { throw DictationError.audioUnavailable }
                    device = found
                }
                try authorization.check {
                    environment.permissionStatus() == .authorized && !environment.secureInputEnabled()
                }
                message = "Mikrofon wird gestartet; noch keine nutzbaren Samples bestätigt …"
                microphone.requestStart(id)
                try await capture.start(session: id, deviceID: device?.id, channel: selectedChannel, policy: policy,
                    authorization: authorization,
                    onFirstSample: { [weak self = self] in
                        Task { @MainActor in
                            guard let self, self.session.id == id, self.session.phase == .preparing else { return }
                            self.microphone.firstSample(id)
                            self.firstSamplePending = true
                            if self.startCompleted, self.session.recording(id) { self.message = "Aufnahme läuft" }
                        }
                    },
                    onProgress: { [weak self = self] seconds, peak in
                        Task { @MainActor in
                            guard let self, self.session.id == id else { return }
                            self.elapsed = seconds; self.level = peak
                        }
                    },
                    onFailure: { [weak self = self] error in
                        Task { @MainActor in
                            self?.microphone.acknowledgeClosed(id)
                            self?.failed(error, id: id)
                        }
                    })
                guard session.id == id, session.phase == .preparing, !quitRequested, !Task.isCancelled else {
                    authorization.invalidate()
                    await capture.cancel(session: id)
                    microphone.acknowledgeClosed(id)
                    throw DictationError.cancelled
                }
                startCompleted = true
                if firstSamplePending, session.recording(id) { message = "Aufnahme läuft" }
            } catch {
                authorization.invalidate()
                await capture.cancel(session: id)
                microphone.acknowledgeClosed(id)
                failed((error as? DictationError) ?? .audioUnavailable, id: id)
            }
        }
    }
    func stop() {
        let requestedStop = environment.nowHostTime()
        guard let id = session.id else { return }
        if session.phase == .preparing { cancel(); return }
        guard session.stopping(id), let cancellation else { return }
        let request = CaptureStopRequest(session: id, cutoffHostTime: requestedStop)
        microphone.requestClose(id)
        operationPending = true; operationNeedsDrain = true
        metrics?.requestedStop = request.cutoffHostTime
        message = "Aufnahmeende wird abgegrenzt …"
        let mode = language
        task = Task {
            defer { finishOperation(); stopPrivacyWatchdog() }
            do {
                let audio = try await capture.stop(request)
                microphone.acknowledgeClosed(id)
                guard session.id == id, !quitRequested, !Task.isCancelled else { throw DictationError.cancelled }
                metrics?.firstSample = audio.firstHostTime
                metrics?.captureClosed = audio.closedHostTime; metrics?.sourceSampleRate = audio.nativeRate
                metrics?.frames16k = audio.pcm.samples.count
                session.transcribing(id)
                level = 0; message = "Mikrofon geschlossen. Lokale Transkription läuft …"
                let result = try await inference.transcribe(audio.pcm, language: mode,
                    cancellation: cancellation, policy: policy)
                guard session.id == id, !quitRequested, !Task.isCancelled else { throw DictationError.cancelled }
                metrics?.finalText = environment.nowHostTime(); metrics?.decodeSeconds = result.decodeSeconds
                session.result(result.text, session: id)
                editedText = result.text
                message = result.text.isEmpty ? "Kein Text erkannt. Mikrofon geschlossen." : "Text bereit zum Prüfen. Mikrofon geschlossen."
                self.cancellation = nil
            } catch {
                // stop errors acknowledge capture shutdown; noAudio means no active producer.
                microphone.acknowledgeClosed(id)
                failed((error as? DictationError) ?? .inferenceFailed, id: id)
            }
        }
    }
    func cancel() {
        guard !closePending else { return }
        let id = session.id
        guard busy || session.phase == .review || !session.rawTranscript.isEmpty || !editedText.isEmpty else { return }
        cancellationGeneration &+= 1
        let generation = cancellationGeneration
        closePending = true
        startupGate?.invalidate(); importAdmission.invalidate()
        microphone.requestClose(id)
        cancellation?.cancel(); task?.cancel()
        session.cancel(); editedText = ""; level = 0
        message = "Abbruch angefordert; Aufnahme wird geschlossen …"
        stopPrivacyWatchdog()
        Task {
            await capture.cancel(session: id)
            microphone.acknowledgeClosed(id)
            guard generation == cancellationGeneration else { return }
            closePending = false
            if session.phase == .cancelled, session.id == nil {
                message = operationPending ? "Mikrofon geschlossen; Abbruch der laufenden Arbeit wird abgewartet …" : "Abgebrochen. Mikrofon geschlossen."
            }
        }
    }
    private func finishOperation() {
        operationPending = false; operationNeedsDrain = false; task = nil
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
    func hidePanel() {
        guard !busy, microphone.state == .closed else { return }
        panel?.hide()
    }
    func copy() {
        guard session.phase == .review, !editedText.isEmpty else { return }
        if LocalClipboard.copy(editedText) {
            message = "Bewusst kopiert. Die Zwischenablage ist für andere lokale Apps lesbar."
        } else { message = "Kopieren fehlgeschlagen. Text bleibt in der Vorschau." }
    }
    func unload() {
        guard !busy else { return }
        operationPending = true; operationNeedsDrain = true
        task = Task {
            defer { finishOperation() }
            await inference.unload()
            message = "Modell aus dem Arbeitsspeicher entladen."
        }
    }
    func configureHotkey() {
        hotkey?.unregister(); hotkey = nil
        guard hotkeyEnabled else { hotkeyStatus = "Globaler Hotkey ist aus"; return }
        do {
            hotkey = try HotkeyService(shortcut: developmentShortcut) { [weak self] down in
                guard let self else { return }
                if environment.secureInputEnabled() { self.cancel(); return }
                if self.holdToTalk {
                    if down { self.start() } else { self.stop() }
                } else if down {
                    if self.session.phase == .recording { self.stop() } else { self.start() }
                }
            }
            hotkeyStatus = developmentShortcut.title + " registriert (vorläufig)"
        } catch {
            hotkeyEnabled = false; hotkeyStatus = "Hotkey-Konflikt oder Registrierung fehlgeschlagen"
        }
    }
    private func startPrivacyWatchdog() {
        stopPrivacyWatchdog()
        cancelPrivacyWatchdog = environment.makeWatchdog { [weak self] in
            guard let self, self.session.phase.isBusy else { return }
            let permission = self.environment.permissionStatus()
            if self.environment.secureInputEnabled() || permission == .denied || permission == .restricted ||
                (self.session.phase != .preparing && permission != .authorized) {
                self.cancel()
            }
        }
    }
    private func stopPrivacyWatchdog() { cancelPrivacyWatchdog?(); cancelPrivacyWatchdog = nil }
    func quit() {
        guard !quitRequested else { return }
        quitRequested = true
        // Resource-free permission waiting must not make Quit depend on a user answer.
        // The main-actor phase changes before the first resource-owning await.
        let pendingOperation = operationNeedsDrain ? task : nil
        cancel(); hotkey?.unregister()
        Task {
            await capture.cancel(session: nil)
            // The cancelled import's bounded copy/hash loop owns and removes its temporary file.
            // Await that cleanup (or an in-flight decoder) before terminating the process.
            await pendingOperation?.value
            await inference.unload()
            environment.terminate()
        }
    }
}
