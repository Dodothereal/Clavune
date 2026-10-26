import AppKit
import AVFoundation
import Carbon
import ClavuneCore
import SwiftUI

/// QA editor copies stay behind the injected in-memory boundary. Production
/// continues to use the native pasteboard sink.
@MainActor
struct QATranscriptClipboardSink: ClipboardWriteSink {
    let write: @MainActor (String) -> Bool

    func prepareForNewContents(with options: NSPasteboard.ContentsOptions) {}
    func setString(_ text: String, forType type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string else { return false }
        return write(text)
    }
}

@MainActor
final class AppCoordinator: ObservableObject {
    private struct DeferredQuitSave {
        let attempt: UUID
        let reviewID: UUID?
        let text: String
    }
    private struct WeakReviewEditor {
        weak var value: TranscriptEditor.Delegate?
    }
    private var reviewEditors: [WeakReviewEditor] = []
    // Native commit publishes editedText synchronously. Reserve commands without
    // publishing the file admission that disables the still-composing editor.
    private var transcriptSavePreparation = OperationAdmission()
    private var quitAfterTranscriptSavePreparation = false

    @Published private(set) var session = SessionMachine()
    @Published private(set) var microphone = MicrophoneLifecycle()
    @Published private(set) var operationPending = false
    @Published private(set) var closePending = false
    @Published private var importAdmission = OperationAdmission()
    @Published private var transcriptAdmission = OperationAdmission()
    @Published private var audioImportAdmission = OperationAdmission()
    @Published private(set) var audioFileSession = false
    @Published private(set) var model: ModelCandidate?
    /// Snapshot of managed files verified by an explicit local check or successful model action.
    /// Every selection re-verifies; this is not a promise that an external file cannot change.
    @Published private(set) var verifiedInstalledModelHashes: Set<String> = []
    @Published private(set) var localModelInventoryChecked = false
    @Published private(set) var modelStatus = "Kein Modell importiert"
    @Published private(set) var message = "Mikrofon geschlossen"
    // High-frequency presentation is observed only by the progress leaf.
    let capturePresentation = CapturePresentationState()
    @Published var editedText = "" {
        didSet {
            guard !TranscriptTextIdentity.matches(editedText, oldValue), session.phase == .review,
                  reviewRevisionSessionID == session.id else { return }
            reviewRevisionCount += 1
        }
    }
    @Published var uiLanguage: UILanguage = .english {
        didSet { preferences?.set(uiLanguage.rawValue, forKey: "uiLanguage") }
    }
    @Published var menuBarEnabled = true {
        didSet {
            preferences?.set(menuBarEnabled, forKey: "menuBarEnabled")
            scenePresentation.setMenuBarEnabled(menuBarEnabled)
        }
    }
    let scenePresentation: ScenePresentationState
    private let preferences: AppPreferences?
    let launchConfiguration: AppLaunchConfiguration
    var isPresentationQA: Bool { launchConfiguration.isQA }
    var qaTranscriptClipboardSink: (any ClipboardWriteSink)? {
        guard launchConfiguration.isQA else { return nil }
        return QATranscriptClipboardSink(write: launchConfiguration.isFunctionalQA
            ? environment.copyText : { _ in false })
    }
    @Published var language: LanguageMode = .auto {
        didSet { preferences?.set(language.rawValue, forKey: "recognitionLanguage") }
    }
    @Published var deviceUID = ""
    @Published var channel = 0
    @Published private(set) var devices: [AudioInputDevice] = []
    @Published private(set) var metrics: SessionMetrics?
    private let localMetricsJournal: LocalMetricsJournal?
    private var reviewRevisionCount = 0
    private var reviewRevisionSessionID: UUID?
    let policy: ResourcePolicy
    let modelCatalogue: ModelCatalogue?
    private let capture: any CaptureServicing
    private let inference: any InferenceServicing
    private let environment: CoordinatorEnvironment
    private let processUsageSnapshot: @MainActor () -> LocalProcessUsageSnapshot?
    private var terminalMetricsRecordedSessionID: UUID?
    private var modelURL: URL?
    private var cancellation: DecodeCancellation?
    private var startupGate: CaptureStartupGate?
    private var task: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var cancelPrivacyWatchdog: (() -> Void)?
    private var operationNeedsDrain = false
    private var hotkey: (any HotkeyRegistration)?
    private var hotkeyGeneration: UInt64 = 0
    private var hotkeyRegistrationReady = false
    private var hotkeyRetirementInProgress = false
    private var hotkeyIsDown = false
    private var hotkeyHeldSessionID: UUID?
    private var shortcutBeforeRecording: DevelopmentShortcut?
    private var hotkeyWasEnabledBeforeRecording = false
    private var functionalQAContext: FunctionalQAContext?
    var functionalQADirectory: URL? { functionalQAContext?.directory }
    private var panel: (any RecordingPanelPresenting)?
    private var startCompleted = false
    private var firstSamplePending = false
    private var pendingLimitRequest: CaptureStopRequest?
    private var quitRequested = false
    @Published private var quitDecisionPending = false
    private var quitAttempt: UUID?
    private var deferredQuitSave: DeferredQuitSave?
    private var modelOperationPending = false
    private var microphoneModelNeedsRevalidation = false
    private var savedReviewID: UUID?
    private var savedReviewText: String?
    private(set) var terminationReady = false
    private var cancellationGeneration: UInt64 = 0
    @Published private(set) var hotkeyEnabled = false
    @Published private(set) var hotkeyRecording = false
    private(set) var hotkeyChordPending = false
    @Published var holdToTalk = true
    @Published private(set) var developmentShortcut: DevelopmentShortcut = .controlShiftSpace {
        didSet { preferences?.set(developmentShortcut.storageValue, forKey: "recordingShortcutV1") }
    }
    @Published private(set) var hotkeyStatus = "Globaler Hotkey ist aus"

    convenience init(policy: ResourcePolicy, launchConfiguration: AppLaunchConfiguration = .production,
                     functionalQATerminate: (@MainActor () -> Void)? = nil) throws {
        let preferences = try launchConfiguration.makePreferences()
        // Synthetic QA must never write production metrics or touch its folder.
        let metricsJournal = launchConfiguration.isQA ? nil : LocalMetricsJournal.applicationDefault()
        if launchConfiguration.isFunctionalQA {
            let context = try FunctionalQAContext(configuration: launchConfiguration)
            self.init(policy: policy, capture: context.capture, inference: context.inference,
                environment: context.environment(terminate: functionalQATerminate ?? { NSApp.terminate(nil) }),
                preferences: preferences.defaults, appPreferences: preferences,
                launchConfiguration: launchConfiguration, modelSelection: context.modelSelection,
                localMetricsJournal: metricsJournal)
            functionalQAContext = context
            modelStatus = "Synthetischer QA-Dienst; keine Modellgewichte geladen"
            message = "Funktions-QA: synthetische Dateien, simulierte Erkennung und Kopie. Mikrofon bleibt geschlossen."
            return
        }
        self.init(policy: policy, capture: CaptureService(), inference: InferenceService(),
                  environment: .live(preferences: preferences), preferences: preferences.defaults,
                  appPreferences: preferences,
                  launchConfiguration: launchConfiguration, localMetricsJournal: metricsJournal)
        restoreManagedModel()
    }
    init(policy: ResourcePolicy, capture: any CaptureServicing, inference: any InferenceServicing,
         environment: CoordinatorEnvironment, preferences: UserDefaults? = nil,
         appPreferences: AppPreferences? = nil,
         launchConfiguration: AppLaunchConfiguration = .production, modelSelection: (candidate: ModelCandidate, url: URL)? = nil,
         localMetricsJournal: LocalMetricsJournal? = nil,
         processUsageSnapshot: @escaping @MainActor () -> LocalProcessUsageSnapshot? = { LocalProcessUsageSnapshot.capture() }) {
        self.launchConfiguration = launchConfiguration
        let selectedPreferences = appPreferences ?? preferences.map {
            AppPreferences(defaults: $0, isolatedSuite: launchConfiguration.preferenceSuite)
        }
        self.preferences = selectedPreferences
        let initialMenuBarEnabled = selectedPreferences?.object(forKey: "menuBarEnabled") as? Bool ?? true
        scenePresentation = ScenePresentationState(menuBarEnabled: initialMenuBarEnabled)
        uiLanguage = UILanguage(rawValue: selectedPreferences?.string(forKey: "uiLanguage") ?? "") ?? .english
        language = LanguageMode(rawValue: selectedPreferences?.string(forKey: "recognitionLanguage") ?? "") ?? .auto
        developmentShortcut = selectedPreferences?.string(forKey: "recordingShortcutV1")
            .flatMap(DevelopmentShortcut.init(storageValue:)) ?? .controlShiftSpace
        menuBarEnabled = initialMenuBarEnabled
        self.localMetricsJournal = launchConfiguration.isQA ? nil : localMetricsJournal
        self.policy = policy; modelCatalogue = try? ModelStore.catalogue()
        self.capture = capture; self.inference = inference; self.environment = environment
        self.processUsageSnapshot = processUsageSnapshot
        model = modelSelection?.candidate; modelURL = modelSelection?.url
        refreshDevices()
        if let center = environment.workspaceNotifications {
            for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.interruptForPrivacy() }
                })
            }
        }
    }
    private var workBusy: Bool { quitRequested || quitDecisionPending || modelOperationPending || operationPending || closePending || importAdmission.isHeld || audioImportAdmission.isHeld || transcriptSavePreparation.isHeld || transcriptAdmission.isHeld || session.phase.isBusy }
    var busy: Bool { hotkeyRecording || workBusy }
    /// A review is owned until deliberately discarded/cancelled, even when its
    /// edited text is empty. Starting another recording must not erase it.
    var hasPendingReview: Bool { session.phase == .review }
    /// A decode is unsaved even before editing. Copy is deliberately not a save.
    var hasUnsavedReview: Bool {
        guard hasPendingReview else { return false }
        guard savedReviewID == session.id, let savedReviewText else { return true }
        return !TranscriptTextIdentity.matches(savedReviewText, editedText)
    }
    private func clearSavedReview() { savedReviewID = nil; savedReviewText = nil }
    private func beginSessionMetrics(id: UUID, source: LocalMetricsEvent.Source) {
        terminalMetricsRecordedSessionID = nil
        var value = SessionMetrics(session: id, requestedStart: environment.nowHostTime(),
                                   processUsageAtStart: processUsageSnapshot())
        value.source = source
        value.requestedLanguage = language.rawValue
        value.modelFileName = model?.fileName
        value.modelSHA256 = model?.sha256
        metrics = value
        reviewRevisionCount = 0
        reviewRevisionSessionID = nil
        recordSessionMetrics(kind: .sessionStarted)
    }
    private func recordSessionMetrics(kind: LocalMetricsEvent.Kind, failureCode: String? = nil) {
        guard let journal = localMetricsJournal, let value = metrics else { return }
        let isTerminal = [.transcriptionCompleted, .sessionFailed, .sessionCancelled, .sessionInterrupted].contains(kind)
        if isTerminal {
            guard terminalMetricsRecordedSessionID != value.session else { return }
            terminalMetricsRecordedSessionID = value.session
        }
        func elapsed(_ start: UInt64?, _ end: UInt64?) -> Double? {
            guard let start, let end, end >= start else { return nil }
            let seconds = AVAudioTime.seconds(forHostTime: end - start)
            return seconds.isFinite && seconds >= 0 ? seconds : nil
        }
        let duration = value.frames16k > 0 ? Double(value.frames16k) / 16_000 : nil
        // Cancellation records the request. Its later resource drain is not part
        // of this event's elapsed time or process usage snapshot.
        let terminalTime = value.finalText ?? (isTerminal ? environment.nowHostTime() : nil)
        let endToEnd = elapsed(value.requestedStart, terminalTime)
        let finalUsage = isTerminal ? processUsageSnapshot() : nil
        let userCPU = finalUsage.flatMap { end in
            value.processUsageAtStart.map { max(0, end.userCPUSeconds - $0.userCPUSeconds) }
        }
        let systemCPU = finalUsage.flatMap { end in
            value.processUsageAtStart.map { max(0, end.systemCPUSeconds - $0.systemCPUSeconds) }
        }
        let event = LocalMetricsEvent(sessionID: value.session, kind: kind, source: value.source,
            requestedLanguage: value.requestedLanguage, detectedLanguageID: value.detectedLanguageID,
            modelFileName: value.modelFileName, modelSHA256: value.modelSHA256,
            backendFingerprint: value.backendFingerprint, sourceSampleRateHz: value.sourceSampleRate,
            processingSampleRateHz: value.processingSampleRate,
            audioFrames16k: value.frames16k, audioDurationSeconds: duration,
            firstSampleDelaySeconds: elapsed(value.requestedStart, value.firstSample),
            recordingDurationSeconds: elapsed(value.firstSample, value.requestedStop),
            stopDrainSeconds: elapsed(value.requestedStop, value.captureClosed),
            captureToResultSeconds: elapsed(value.captureClosed, value.finalText),
            recognizedWordCount: value.recognizedWordCount,
            wordsPerMinute: value.recognizedWordCount.flatMap {
                LocalMetricsEvent.wordsPerMinute(words: $0, audioSeconds: duration)
            }, modelWarm: value.modelLoadSeconds == nil ? nil : value.modelWarm,
            modelLoadSeconds: value.modelLoadSeconds,
            audioPreparationSeconds: value.audioPreparationSeconds, decodeSeconds: value.decodeSeconds,
            endToEndSeconds: value.audioImportTotalSeconds ?? endToEnd,
            processCPUUserSeconds: userCPU, processCPUSystemSeconds: systemCPU,
            processPeakRSSBytesAtEvent: finalUsage?.peakRSSBytes, failureCode: failureCode)
        journal.record(event)
    }
    private func recordReviewAction(_ action: LocalMetricsEvent.ReviewAction, succeeded: Bool,
                                   editedWordCount: Int? = nil, editorRevisionCount: Int? = nil) {
        guard let journal = localMetricsJournal else { return }
        let reviewID = hasPendingReview ? session.id : nil
        let context = metrics.flatMap { $0.session == reviewID ? $0 : nil }
        // An idle document attempt owns a fresh event identity, with no metadata
        // retained from a previous cancelled or failed dictation.
        journal.record(LocalMetricsEvent(sessionID: reviewID ?? UUID(), kind: .reviewAction,
            source: context?.source ?? .transcriptFile, requestedLanguage: context?.requestedLanguage,
            modelFileName: context?.modelFileName, modelSHA256: context?.modelSHA256,
            backendFingerprint: context?.backendFingerprint, reviewAction: action,
            actionSucceeded: succeeded,
            rawWordCount: reviewID == nil ? 0 : LocalMetricsEvent.wordCount(session.rawTranscript),
            editedWordCount: editedWordCount ?? (reviewID == nil ? 0 : LocalMetricsEvent.wordCount(editedText)),
            editorRevisionCount: editorRevisionCount ??
                (reviewID != nil && reviewRevisionSessionID == reviewID ? reviewRevisionCount : 0)))
    }
    var canStart: Bool {
        !isPresentationQA && !busy && model != nil && !hasPendingReview && !microphoneModelNeedsRevalidation
    }
    var canStop: Bool {
        !audioFilePending && [.preparing, .recording].contains(session.phase)
    }
    var selectedModelNeedsRevalidation: Bool { model != nil && microphoneModelNeedsRevalidation }
    var canRestoreManagedModel: Bool {
        !isPresentationQA && !busy && !hasPendingReview && microphone.state == .closed &&
            model == nil && preferences?.string(forKey: "selectedModelSHA256") != nil
    }
    var audioFilePending: Bool { audioImportAdmission.isHeld }
    var canImportAudio: Bool {
        !launchConfiguration.isNativePanelQA &&
            (canStart || (launchConfiguration.isFunctionalQA && !busy && model != nil && !hasPendingReview)) &&
            microphone.state == .closed
    }
    var transcriptFilePending: Bool { transcriptAdmission.isHeld }
    var canOpenTranscript: Bool { (!isPresentationQA || launchConfiguration.isFunctionalQA) && !busy && microphone.state == .closed }
    var canSaveTranscript: Bool { canOpenTranscript && hasPendingReview && !environment.statisticsExportActive() }
    func registerReviewEditor(_ editor: TranscriptEditor.Delegate) {
        reviewEditors.removeAll { $0.value == nil || $0.value === editor }
        reviewEditors.append(WeakReviewEditor(value: editor))
    }
    func unregisterReviewEditor(_ editor: TranscriptEditor.Delegate) {
        reviewEditors.removeAll { $0.value == nil || $0.value === editor }
    }
    private func commitPendingReviewText() -> Bool {
        reviewEditors.removeAll { $0.value == nil }
        var pending: [(TranscriptEditor.Delegate, String)] = []
        for editor in reviewEditors.compactMap(\.value) {
            switch editor.pendingSaveCommit(reviewID: session.id, boundText: editedText) {
            case .none: break
            case .blocked: return false
            case .text(let text): pending.append((editor, text))
            }
        }
        guard let first = pending.first else { return true }
        // Two hosts must not choose arbitrarily between different live drafts.
        guard pending.allSatisfy({ TranscriptTextIdentity.matches($0.1, first.1) }) else { return false }
        return first.0.commitPendingSaveText(first.1)
    }
    /// Direct Quit must make native marked text part of the dirty-review decision.
    /// Reentrant Quit from the real binding publication coalesces with this request.
    private func commitPendingReviewTextBeforeQuit() -> Bool {
        guard let preparation = transcriptSavePreparation.begin() else { return false }
        let generation = cancellationGeneration, reviewID = session.id
        let committed = commitPendingReviewText()
        // This Quit is already handling the reentrant request; unlike a Save,
        // replaying it would show a second dirty-review decision.
        quitAfterTranscriptSavePreparation = false
        transcriptSavePreparation.finish(preparation)
        guard committed else {
            message = "Beenden abgebrochen. Die Vorschau bleibt erhalten."
            return false
        }
        guard generation == cancellationGeneration, session.id == reviewID,
              hasPendingReview, !quitRequested else { return false }
        return true
    }
    private func cancelTranscriptSavePreparation() {
        quitAfterTranscriptSavePreparation = false
        transcriptSavePreparation.invalidate()
        cancellationGeneration &+= 1
        if quitDecisionPending { finishQuitDecision() }
        message = "Dateivorgang abgebrochen. Die Vorschau bleibt erhalten. Ein bereits gestartetes Speichern kann abgeschlossen sein."
    }
    func attachPanel(_ panel: any RecordingPanelPresenting) { self.panel = panel }
    func revealPanelIfBusy() {
        guard busy || microphone.state != .closed else { return }
        panel?.show(force: true)
    }
    func refreshDevices() { devices = environment.inputDevices() }

    func importModel() {
        guard !isPresentationQA, !busy, let admission = importAdmission.begin() else { return }
        modelOperationPending = true
        let generation = cancellationGeneration
        guard let selected = environment.chooseModel(),
              importAdmission.permits(admission), generation == cancellationGeneration,
              !closePending, !session.phase.isBusy else {
            importAdmission.finish(admission); modelOperationPending = false
            resumeDeferredQuitSaveIfReady()
            return
        }
        // Only an admitted selection starts fresh; cancelling the picker is a no-op.
        if session.phase == .cancelled { session.discard() }
        operationPending = true; operationNeedsDrain = true; modelStatus = "Modell wird lokal geprüft …"
        task = Task {
            defer {
                if Task.isCancelled || generation != cancellationGeneration {
                    modelStatus = model == nil ? "Import abgebrochen; kein Modell ausgewählt" : "Import abgebrochen; bisheriges Modell ausgewählt"
                }
                importAdmission.finish(admission); modelOperationPending = false; finishOperation()
                resumeDeferredQuitSaveIfReady()
            }
            do {
                let importModel = environment.importManagedModel
                let importTask = Task.detached(priority: .utility) {
                    try importModel(selected)
                }
                let installed = try await withTaskCancellationHandler {
                    try await importTask.value
                } onCancel: { importTask.cancel() }
                guard !Task.isCancelled, generation == cancellationGeneration else {
                    // A completed activation can replace the selected inode before
                    // cancellation rejects its result. Drain the old context now;
                    // a later retry may see the replacement as verified reuse.
                    if !installed.reusedVerifiedFile, modelURL == installed.url {
                        await inference.unload()
                    }
                    return
                }
                // Reuse only the same selected, freshly verified managed file.
                // Recovery replaces the inode even for the same SHA and must unload.
                let preservesWarmModel = installed.reusedVerifiedFile &&
                    model?.sha256 == installed.candidate.sha256 &&
                    model?.sizeBytes == installed.candidate.sizeBytes && modelURL == installed.url
                if !preservesWarmModel {
                    await inference.unload()
                    guard !Task.isCancelled, generation == cancellationGeneration else { return }
                }
                resolveMicrophoneModelFailureAfterVerification()
                model = installed.candidate; modelURL = installed.url
                verifiedInstalledModelHashes.insert(installed.candidate.sha256)
                preferences?.set(installed.candidate.sha256, forKey: "selectedModelSHA256")
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

    func downloadModel(_ candidate: ModelCandidate) {
        guard !isPresentationQA, !busy, candidate.downloadEnabled,
              modelCatalogue?.models.contains(where: {
                  $0.sha256 == candidate.sha256 && $0.fileName == candidate.fileName &&
                      $0.sizeBytes == candidate.sizeBytes && $0.license == candidate.license &&
                      $0.role == candidate.role && $0.sourceURL == candidate.sourceURL &&
                      $0.sourceRevision == candidate.sourceRevision && $0.downloadEnabled == candidate.downloadEnabled
              }) == true,
              let admission = importAdmission.begin() else { return }
        // A fresh admitted download owns its result, without discarding a review.
        if session.phase == .cancelled { session.discard() }
        modelOperationPending = true
        let generation = cancellationGeneration
        operationPending = true; operationNeedsDrain = true
        modelStatus = "Modell-Download wird vorbereitet …"
        task = Task {
            defer {
                if Task.isCancelled || generation != cancellationGeneration {
                    modelStatus = model == nil ? "Download abgebrochen; kein Modell ausgewählt" : "Download abgebrochen; bisheriges Modell ausgewählt"
                }
                importAdmission.finish(admission); modelOperationPending = false; finishOperation()
            }
            do {
                let download = environment.downloadManagedModel
                let report: @Sendable (Int64) -> Void = { [weak owner = self] received in
                    guard let owner else { return }
                    Task { @MainActor [weak self = owner] in
                        guard let self, generation == self.cancellationGeneration,
                              self.importAdmission.permits(admission), self.modelOperationPending else { return }
                        self.modelStatus = "\(candidate.fileName): \(received) / \(candidate.sizeBytes) Bytes"
                    }
                }
                let installed = try await download(candidate, report)
                guard !Task.isCancelled, generation == cancellationGeneration else {
                    if !installed.reusedVerifiedFile && modelURL == installed.url { await inference.unload() }
                    return
                }
                let preservesWarmModel = installed.reusedVerifiedFile &&
                    model?.sha256 == installed.candidate.sha256 &&
                    model?.sizeBytes == installed.candidate.sizeBytes && modelURL == installed.url
                if !preservesWarmModel {
                    await inference.unload()
                    guard !Task.isCancelled, generation == cancellationGeneration else { return }
                }
                resolveMicrophoneModelFailureAfterVerification()
                model = installed.candidate; modelURL = installed.url
                verifiedInstalledModelHashes.insert(installed.candidate.sha256)
                preferences?.set(installed.candidate.sha256, forKey: "selectedModelSHA256")
                modelStatus = installed.candidate.fileName + " — Hash geprüft, Qualität noch ungemessen"
                message = "Modell bereit. Mikrofon geschlossen."
            } catch {
                guard !Task.isCancelled, generation == cancellationGeneration else { return }
                modelStatus = "Modelldownload fehlgeschlagen"
                message = uiLanguage.downloadFailureMessage(for: error)
            }
        }
    }

    /// Deliberate read-only local hash check. No source URL, download or default selection.
    func checkInstalledModels() {
        guard !isPresentationQA, !busy, microphone.state == .closed,
              let candidates = modelCatalogue?.models,
              let admission = importAdmission.begin() else { return }
        // A new admitted action owns its result message after an earlier cancel.
        // Never discard an active review here.
        if session.phase == .cancelled { session.discard() }
        let generation = cancellationGeneration
        verifiedInstalledModelHashes.removeAll()
        localModelInventoryChecked = false
        modelOperationPending = true
        operationPending = true; operationNeedsDrain = true
        message = "Lokale Modelldateien werden geprüft …"
        task = Task {
            defer {
                importAdmission.finish(admission); modelOperationPending = false; finishOperation()
                resumeDeferredQuitSaveIfReady()
            }
            let restore = environment.restoreManagedSelection
            let verification = Task.detached(priority: .utility) { () throws -> Set<String> in
                var verified = Set<String>()
                for candidate in candidates {
                    try Task.checkCancellation()
                    do {
                        let installed = try restore(candidate.sha256)
                        guard installed.candidate.sha256 == candidate.sha256,
                              installed.candidate.fileName == candidate.fileName,
                              installed.candidate.sizeBytes == candidate.sizeBytes else { continue }
                        verified.insert(candidate.sha256)
                    } catch {
                        try Task.checkCancellation()
                        // Missing, inaccessible and invalid files are never called installed.
                    }
                }
                return verified
            }
            do {
                let verified = try await withTaskCancellationHandler {
                    try await verification.value
                } onCancel: { verification.cancel() }
                guard !Task.isCancelled, generation == cancellationGeneration,
                      importAdmission.permits(admission) else { return }
                verifiedInstalledModelHashes = verified
                localModelInventoryChecked = true
                if let selected = model?.sha256, !verified.contains(selected) {
                    microphoneModelNeedsRevalidation = true
                    modelStatus = "Ausgewähltes Modell lokal nicht mehr gültig oder nicht verfügbar"
                    message = "Ausgewählte Modelldatei ist ungültig oder nicht verfügbar. Aufnahme gesperrt; bitte erneut lokal prüfen, importieren oder bewusst herunterladen."
                } else {
                    if let current = model {
                        resolveMicrophoneModelFailureAfterVerification()
                        modelStatus = current.fileName + " — Hash geprüft, Qualität noch ungemessen"
                    }
                    message = "Lokale Modellprüfung abgeschlossen. Auswahl prüft die Datei erneut; kein Modelldownload."
                }
            } catch {
                guard generation == cancellationGeneration else { return }
                message = "Lokale Modellprüfung abgebrochen. Keine Auswahl geändert."
            }
        }
    }

    /// Re-checks the exact managed file before changing selection. Never downloads.
    func selectInstalledModel(_ candidate: ModelCandidate) {
        guard !isPresentationQA, !busy, microphone.state == .closed,
              verifiedInstalledModelHashes.contains(candidate.sha256),
              modelCatalogue?.models.contains(where: {
                  $0.sha256 == candidate.sha256 && $0.fileName == candidate.fileName &&
                      $0.sizeBytes == candidate.sizeBytes && $0.license == candidate.license &&
                      $0.role == candidate.role && $0.sourceURL == candidate.sourceURL &&
                      $0.sourceRevision == candidate.sourceRevision && $0.downloadEnabled == candidate.downloadEnabled
              }) == true,
              let admission = importAdmission.begin() else { return }
        if session.phase == .cancelled { session.discard() }
        let generation = cancellationGeneration
        let previousStatus = modelStatus
        modelOperationPending = true
        operationPending = true; operationNeedsDrain = true
        modelStatus = "Lokales Modell wird erneut geprüft …"
        task = Task {
            defer {
                if Task.isCancelled || generation != cancellationGeneration { modelStatus = previousStatus }
                importAdmission.finish(admission); modelOperationPending = false; finishOperation()
                resumeDeferredQuitSaveIfReady()
            }
            do {
                let restore = environment.restoreManagedSelection
                let verification = Task.detached(priority: .utility) { try restore(candidate.sha256) }
                let installed = try await withTaskCancellationHandler {
                    try await verification.value
                } onCancel: { verification.cancel() }
                guard !Task.isCancelled, generation == cancellationGeneration,
                      importAdmission.permits(admission) else { return }
                guard installed.candidate.sha256 == candidate.sha256,
                      installed.candidate.fileName == candidate.fileName,
                      installed.candidate.sizeBytes == candidate.sizeBytes else {
                    throw DictationError.modelMismatch
                }
                // A path/hash match does not establish that a warm engine still
                // owns the verified inode after an external file replacement.
                await inference.unload()
                guard !Task.isCancelled, generation == cancellationGeneration,
                      importAdmission.permits(admission) else { return }
                resolveMicrophoneModelFailureAfterVerification()
                model = installed.candidate; modelURL = installed.url
                verifiedInstalledModelHashes.insert(installed.candidate.sha256)
                preferences?.set(installed.candidate.sha256, forKey: "selectedModelSHA256")
                modelStatus = installed.candidate.fileName + " — Hash geprüft, Qualität noch ungemessen"
                message = "Lokales Modell ausgewählt. Kein Download. Mikrofon geschlossen."
            } catch {
                guard !Task.isCancelled, generation == cancellationGeneration else { return }
                verifiedInstalledModelHashes.remove(candidate.sha256)
                modelStatus = previousStatus
                message = "Lokales Modell nicht mehr gültig oder nicht verfügbar. Bisherige Auswahl bleibt erhalten. Bewusst importieren oder herunterladen."
            }
        }
    }

    /// Restore only an explicitly selected, catalogued managed file. No scanning,
    /// app download/HTTP request, default selection, recovery mutation, or eager inference load.
    func restoreManagedModel() {
        guard canRestoreManagedModel,
              let hash = preferences?.string(forKey: "selectedModelSHA256") else { return }
        // Admission requires the prior operation and microphone close to have drained.
        // Clear only its terminal cancellation, never a pending review or active capture.
        // Otherwise finishOperation would overwrite this retry's result with "Cancelled".
        if session.phase == .cancelled { session.discard() }
        let generation = cancellationGeneration
        operationPending = true; operationNeedsDrain = true
        modelStatus = "Gespeichertes Modell wird geprüft …"
        modelOperationPending = true
        task = Task {
            defer {
                if Task.isCancelled || generation != cancellationGeneration {
                    modelStatus = "Modellprüfung abgebrochen; kein Modell ausgewählt"
                }
                modelOperationPending = false; finishOperation()
            }
            do {
                let restore = environment.restoreManagedSelection
                let verification = Task.detached(priority: .utility) {
                    try restore(hash)
                }
                let installed = try await withTaskCancellationHandler {
                    try await verification.value
                } onCancel: { verification.cancel() }
                guard !Task.isCancelled, generation == cancellationGeneration else { return }
                resolveMicrophoneModelFailureAfterVerification()
                model = installed.candidate; modelURL = installed.url
                verifiedInstalledModelHashes.insert(installed.candidate.sha256)
                modelStatus = installed.candidate.fileName + " — Hash geprüft, Qualität noch ungemessen"
                message = "Modell bereit. Mikrofon geschlossen."
            } catch {
                guard !Task.isCancelled, generation == cancellationGeneration else { return }
                modelStatus = "Gespeichertes Modell nicht verfügbar oder ungültig"
                message = "Bitte das Modell erneut bewusst importieren. Vorhandene Dateien wurden nicht verändert."
            }
        }
    }
    func start() {
        guard !busy else { return }
        guard !hasPendingReview else {
            message = "Die aktuelle Vorschau bleibt erhalten. Bei Bedarf kopieren, dann verwerfen, um erneut aufzunehmen."
            panel?.show(force: false)
            return
        }
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
        audioFileSession = false
        operationPending = true; operationNeedsDrain = false
        let authorization = CaptureStartupGate()
        startupGate = authorization
        startCompleted = false; firstSamplePending = false; pendingLimitRequest = nil
        editedText = ""; capturePresentation.reset()
        beginSessionMetrics(id: id, source: .microphone)
        message = "Mikrofon geschlossen; Modell und Berechtigung werden vorbereitet …"
        panel?.show(force: false)
        let selectedUID = deviceUID
        let selectedChannel = channel
        startPrivacyWatchdog()
        task = Task {
            defer {
                finishOperation()
                if let request = pendingLimitRequest {
                    pendingLimitRequest = nil
                    captureReachedLimit(request)
                }
            }
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
                let dispatchProgress = environment.dispatchCaptureProgress
                let dispatchLifecycle = environment.dispatchCaptureLifecycle
                try await capture.start(session: id, deviceID: device?.id, channel: selectedChannel, policy: policy,
                    authorization: authorization,
                    onFirstSample: { [weak owner = self] in
                        guard let strongOwner = owner else { return }
                        dispatchLifecycle { [weak coordinator = strongOwner] in
                            guard let coordinator, coordinator.session.id == id,
                                  coordinator.session.phase == .preparing else { return }
                            coordinator.microphone.firstSample(id)
                            coordinator.firstSamplePending = true
                            if coordinator.startCompleted, coordinator.session.recording(id) {
                                coordinator.message = "Aufnahme läuft"
                            }
                        }
                    },
                    onProgress: { [weak self = self] seconds, peak in
                        dispatchProgress { [weak self] in
                            guard let self, self.session.id == id,
                                  [.preparing, .recording, .stopping].contains(self.session.phase),
                                  self.microphone.state != .closed else { return }
                            self.capturePresentation.accept(seconds: seconds, peak: peak)
                        }
                    },
                    onFailure: { [weak owner = self] error in
                        guard let strongOwner = owner else { return }
                        dispatchLifecycle { [weak coordinator = strongOwner] in
                            guard let coordinator, coordinator.session.id == id,
                                  [.preparing, .recording, .stopping].contains(coordinator.session.phase),
                                  coordinator.microphone.state != .closed else { return }
                            coordinator.microphone.acknowledgeClosed(id)
                            coordinator.failed(error, id: id)
                        }
                    },
                    onLimitReached: { [weak owner = self] request in
                        guard let strongOwner = owner else { return }
                        dispatchLifecycle { [weak coordinator = strongOwner] in
                            coordinator?.captureReachedLimit(request)
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
        // A hold-hotkey key-up must not cancel a file operation whose key-down
        // could not start recording. The command boundary, not only UI, owns this.
        guard !audioFilePending else { return }
        let requestedStop = environment.nowHostTime()
        guard let id = session.id else { return }
        if session.phase == .preparing { cancel(); return }
        stop(CaptureStopRequest(session: id, cutoffHostTime: requestedStop))
    }
    private func captureReachedLimit(_ request: CaptureStopRequest) {
        guard session.id == request.session, !quitRequested, !closePending,
              [.preparing, .recording].contains(session.phase) else { return }
        microphone.acknowledgeClosed(request.session)
        if !startCompleted || operationPending {
            // A queued callback may beat the startup continuation. Do not overwrite
            // its task/admission: its defer hands this request over after draining.
            pendingLimitRequest = request; firstSamplePending = true
            return
        }
        // A completed nonempty buffer proves first-sample delivery even if its
        // separate MainActor callback was delayed or reordered behind this one.
        if session.phase == .preparing { _ = session.recording(request.session) }
        stop(request)
    }
    private func stop(_ request: CaptureStopRequest) {
        let id = request.session
        guard session.stopping(id), let cancellation else { return }
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
                guard session.id == id, session.phase == .stopping, !quitRequested, !Task.isCancelled else { throw DictationError.cancelled }
                metrics?.firstSample = audio.firstHostTime
                metrics?.captureClosed = audio.closedHostTime; metrics?.sourceSampleRate = audio.nativeRate
                metrics?.processingSampleRate = 16_000
                metrics?.frames16k = audio.pcm.samples.count
                session.transcribing(id)
                capturePresentation.clearLevel()
                message = audio.completionReason == .sessionLimit
                    ? "Sitzungslimit erreicht. Mikrofon geschlossen; aufgenommener Abschnitt wird lokal transkribiert …"
                    : "Mikrofon geschlossen. Lokale Transkription läuft …"
                let result = try await inference.transcribe(audio.pcm, language: mode,
                    cancellation: cancellation, policy: policy)
                guard session.id == id, session.phase == .transcribing, !quitRequested, !Task.isCancelled else { throw DictationError.cancelled }
                metrics?.finalText = environment.nowHostTime(); metrics?.decodeSeconds = result.decodeSeconds
                // A fixed language is a request, not a detection by the backend.
                metrics?.detectedLanguageID = mode == .auto && result.languageID >= 0 ? result.languageID : nil
                metrics?.recognizedWordCount = LocalMetricsEvent.wordCount(result.text)
                session.result(result.text, session: id)
                editedText = result.text
                reviewRevisionCount = 0; reviewRevisionSessionID = id
                recordSessionMetrics(kind: .transcriptionCompleted)
                if audio.completionReason == .sessionLimit {
                    message = result.text.isEmpty
                        ? "Sitzungslimit erreicht. Kein Text erkannt. Mikrofon geschlossen."
                        : "Sitzungslimit erreicht. Text des aufgenommenen Abschnitts bereit zum Prüfen. Mikrofon geschlossen."
                } else {
                    message = result.text.isEmpty ? "Kein Text erkannt. Mikrofon geschlossen." : "Text bereit zum Prüfen. Mikrofon geschlossen."
                }
                self.cancellation = nil
            } catch {
                // stop errors acknowledge capture shutdown; noAudio means no active producer.
                microphone.acknowledgeClosed(id)
                failed((error as? DictationError) ?? .inferenceFailed, id: id)
            }
        }
    }
    /// Automatic privacy events stop resource work, not a completed user's review.
    /// A review can coexist with model work, so busy work must still be cancelled.
    func interruptForPrivacy() {
        // Recording a shortcut owns no capture, but an interrupted application
        // must not keep the focused recorder or restore a global registration.
        if hotkeyRecording { abortHotkeyRecordingForPrivacy(); return }
        // Sleep/resign and Secure Input may lose the release edge of a held
        // shortcut. Retire its Carbon identity rather than leaving either
        // pressed latch stuck; re-enabling after privacy recovery is explicit.
        if hotkeyEnabled || hotkey != nil {
            hotkeyRetirementInProgress = true
            hotkeyGeneration &+= 1
            hotkeyRegistrationReady = false
            hotkeyEnabled = false
            hotkeyIsDown = false; hotkeyHeldSessionID = nil
            let retired = hotkey; hotkey = nil
            retired?.unregister()
            hotkeyRetirementInProgress = false
            hotkeyStatus = "Datenschutz-Unterbrechung; Hotkey aus. Bei Bedarf bewusst erneut aktivieren."
        }
        if transcriptSavePreparation.isHeld { cancelTranscriptSavePreparation(); return }
        if quitDecisionPending { finishQuitDecision() }
        if modelOperationPending, hasPendingReview { cancelModelOperationPreservingReview(); return }
        if audioFilePending { cancelAudioImport(); return }
        if transcriptFilePending { cancelTranscriptFile(); return }
        guard busy || microphone.state != .closed else { return }
        cancel(preservingReview: true)
    }
    func cancel() {
        if hotkeyRecording { cancelHotkeyRecording(); return }
        if transcriptSavePreparation.isHeld { cancelTranscriptSavePreparation(); return }
        // Cancel during a Quit decision means keep this review, including a Save
        // picker or a queued save-after-drain. It must never become review discard.
        if quitDecisionPending {
            finishQuitDecision()
            if transcriptFilePending { cancelTranscriptFile() }
            else if modelOperationPending { cancelModelOperationPreservingReview() }
            return
        }
        if modelOperationPending, hasPendingReview { cancelModelOperationPreservingReview(); return }
        if audioFilePending { cancelAudioImport(); return }
        if transcriptFilePending { cancelTranscriptFile(); return }
        // Explicit Cancel/Quit can arrive during a review-preserving close drain.
        // Reuse that drain, but do not let its admission guard ignore this intent.
        if closePending, hasPendingReview {
            recordReviewAction(.discard, succeeded: true)
            session.cancel(); editedText = ""; clearSavedReview()
            message = "Abbruch angefordert; Aufnahme wird geschlossen …"
        }
        cancel(preservingReview: false)
    }
    private func cancelModelOperationPreservingReview() {
        // Model work owns no microphone/review. Keep its admission until the real
        // detached import/unload returns; cancellation cannot erase editor identity.
        importAdmission.invalidate()
        if !closePending { cancellationGeneration &+= 1 }
        task?.cancel()
        if hasPendingReview { recordReviewAction(.cancel, succeeded: true) }
        message = "Modellvorgang abgebrochen. Die Vorschau bleibt erhalten."
    }
    private func cancel(preservingReview: Bool) {
        guard !closePending else { return }
        let id = session.id
        guard busy || session.phase == .review || !session.rawTranscript.isEmpty || !editedText.isEmpty else { return }
        let keepReview = preservingReview && hasPendingReview
        if session.phase.isBusy {
            recordSessionMetrics(kind: .sessionCancelled, failureCode: DictationError.cancelled.rawValue)
        } else if hasPendingReview && !preservingReview {
            recordReviewAction(.discard, succeeded: true)
        }
        cancellationGeneration &+= 1
        let generation = cancellationGeneration
        closePending = true
        startupGate?.invalidate(); importAdmission.invalidate(); pendingLimitRequest = nil
        microphone.requestClose(id)
        cancellation?.cancel(); task?.cancel()
        if !keepReview {
            session.cancel(); editedText = ""; clearSavedReview()
            message = "Abbruch angefordert; Aufnahme wird geschlossen …"
        }
        capturePresentation.clearLevel()
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
    private func finishOperation(preservingMessage: Bool = false) {
        operationPending = false; operationNeedsDrain = false; task = nil
        if !preservingMessage, session.phase == .cancelled, !closePending {
            message = "Abgebrochen. Mikrofon geschlossen."
        }
    }
    private func resolveMicrophoneModelFailureAfterVerification() {
        guard microphoneModelNeedsRevalidation else { return }
        microphoneModelNeedsRevalidation = false
        if session.phase == .failed,
           let failure = session.failure,
           [.modelMissing, .modelMismatch, .modelInvalid].contains(failure) {
            session.discard()
            editedText = ""
            metrics = nil
            clearSavedReview()
        }
    }
    private func failed(_ error: DictationError, id: UUID) {
        guard session.id == id, session.phase.isBusy else { return }
        if !audioFileSession, [.modelMissing, .modelMismatch, .modelInvalid].contains(error) {
            // A failed microphone model load is not a retryable recording error.
            // Require a deliberate model verification/import before enabling Start.
            microphoneModelNeedsRevalidation = true
        }
        recordSessionMetrics(kind: error == .cancelled ? .sessionCancelled : .sessionFailed,
                             failureCode: error.rawValue)
        session.fail(error, session: id); cancellation = nil; capturePresentation.clearLevel()
        message = error.localizedDescription; stopPrivacyWatchdog()
    }
    func discard() {
        guard !busy else { return }
        if hasPendingReview { recordReviewAction(.discard, succeeded: true) }
        session.discard(); editedText = ""; metrics = nil; audioFileSession = false
        clearSavedReview()
        message = "Verworfen. Mikrofon geschlossen."; panel?.hide()
    }
    var canHidePanel: Bool { !busy && microphone.state == .closed }
    /// Safe even while busy: controls have a visible replacement host first.
    func handoffPanelToMainWindow(isVisible: Bool) {
        guard isVisible else { return }
        panel?.hide()
    }
    func hidePanel() {
        guard canHidePanel else { return }
        panel?.hide()
    }
    func copy() {
        guard session.phase == .review, !editedText.isEmpty else { return }
        let copied = environment.copyText(editedText)
        recordReviewAction(.copy, succeeded: copied)
        if copied {
            message = launchConfiguration.isFunctionalQA
                ? "QA-Kopie nur im Arbeitsspeicher. Die Systemzwischenablage bleibt unverändert."
                : "Bewusst kopiert. Die Zwischenablage ist für andere lokale Apps lesbar."
        } else { message = "Kopieren fehlgeschlagen. Text bleibt in der Vorschau." }
    }
    /// Existing reviews must be explicitly discarded first. The picker itself holds
    /// admission, because its modal loop can dispatch nested commands/Cancel/Quit.
    func importAudio() {
        guard canImportAudio, let model, let modelURL,
              let admission = audioImportAdmission.begin() else { return }
        let generation = cancellationGeneration
        guard let url = environment.chooseAudioToImport(uiLanguage),
              audioImportAdmission.permits(admission), generation == cancellationGeneration,
              !quitRequested, !hasPendingReview, microphone.state == .closed else {
            audioImportAdmission.finish(admission); return
        }
        let id: UUID, token: DecodeCancellation
        do {
            let admitted = try session.begin(preparing: environment.makeCancellation)
            id = admitted.id; token = admitted.resource; cancellation = token
        } catch {
            audioImportAdmission.finish(admission)
            message = "Audioimport konnte nicht gestartet werden. Bitte erneut versuchen."
            return
        }
        audioFileSession = true
        operationPending = true; operationNeedsDrain = true
        editedText = ""; capturePresentation.reset()
        beginSessionMetrics(id: id, source: .audioFile)
        message = "Audiodatei wird lokal geprüft und konvertiert. Mikrofon geschlossen."
        panel?.show(force: false)
        let mode = language, importPolicy = policy, read = environment.readAudio
        task = Task {
            defer {
                cancellation = nil
                audioImportAdmission.finish(admission)
                finishOperation(preservingMessage: true)
            }
            var audioValidated = false
            do {
                try Task.checkCancellation()
                let reading = Task.detached(priority: .utility) { try read(url, importPolicy) }
                let pcm = try await withTaskCancellationHandler {
                    try await reading.value
                } onCancel: { reading.cancel() }
                guard !Task.isCancelled, session.id == id, !quitRequested,
                      audioImportAdmission.permits(admission), generation == cancellationGeneration else { return }
                audioValidated = true
                let prepared = environment.nowHostTime()
                if let requested = metrics?.requestedStart, prepared >= requested {
                    metrics?.audioPreparationSeconds = AVAudioTime.seconds(forHostTime: prepared - requested)
                }
                // The importer has normalized to 16 kHz and does not currently
                // expose the original encoded stream rate.
                metrics?.sourceSampleRate = nil
                metrics?.processingSampleRate = 16_000
                metrics?.frames16k = pcm.samples.count
                let warm = try await inference.load(url: modelURL, candidate: model)
                guard !Task.isCancelled, session.id == id, !quitRequested,
                      audioImportAdmission.permits(admission), generation == cancellationGeneration else { return }
                metrics?.modelWarm = warm.warm; metrics?.modelLoadSeconds = warm.seconds
                guard session.transcribingImportedAudio(id) else { return }
                message = "Audiodatei wird lokal transkribiert. Mikrofon geschlossen."
                let result = try await inference.transcribe(pcm, language: mode, cancellation: token, policy: importPolicy)
                guard !Task.isCancelled, session.id == id, !quitRequested,
                      audioImportAdmission.permits(admission), generation == cancellationGeneration else { return }
                let finished = environment.nowHostTime()
                metrics?.finalText = finished; metrics?.decodeSeconds = result.decodeSeconds
                // A fixed language is a request, not a detection by the backend.
                metrics?.detectedLanguageID = mode == .auto && result.languageID >= 0 ? result.languageID : nil
                metrics?.recognizedWordCount = LocalMetricsEvent.wordCount(result.text)
                if let requested = metrics?.requestedStart, finished >= requested {
                    metrics?.audioImportTotalSeconds = AVAudioTime.seconds(forHostTime: finished - requested)
                }
                session.result(result.text, session: id); editedText = result.text
                reviewRevisionCount = 0; reviewRevisionSessionID = id
                recordSessionMetrics(kind: .transcriptionCompleted)
                message = result.text.isEmpty ? "Kein Text erkannt. Mikrofon geschlossen." : "Text bereit zum Prüfen. Mikrofon geschlossen."
            } catch {
                guard !Task.isCancelled, session.id == id, generation == cancellationGeneration else { return }
                let failure: DictationError
                if let importer = error as? AudioFileImporter.Failure {
                    switch importer {
                    case .durationLimit: failure = .durationLimit
                    case .noAudio: failure = .noAudio
                    case .invalidFile, .tooLarge, .unsupportedFormat, .changedFile:
                        // There is no separate file-size/integrity case in
                        // DictationError; preserve the existing fallback code.
                        failure = .unsupportedFormat
                    }
                } else {
                    failure = (error as? DictationError) ?? .unsupportedFormat
                }
                recordSessionMetrics(kind: failure == .cancelled ? .sessionCancelled : .sessionFailed,
                                     failureCode: failure.rawValue)
                session.fail(failure, session: id)
                message = audioValidated
                    ? "Lokale Datei-Transkription fehlgeschlagen. Modell prüfen und die Datei bewusst erneut importieren."
                    : "Audioimport fehlgeschlagen. M4A (AAC-LC/ALAC), AAC-LC, MP3 oder PCM-WAV in Mono/Stereo wählen; höchstens 120 s und 64 MiB. Keine Datei wurde verändert."
            }
        }
    }
    private func cancelAudioImport() {
        recordSessionMetrics(kind: .sessionCancelled, failureCode: DictationError.cancelled.rawValue)
        audioImportAdmission.invalidate(); cancellationGeneration &+= 1
        cancellation?.cancel(); task?.cancel()
        // Picker cancellation has no session to erase. Admitted work remains busy
        // until conversion/model/decode cleanup actually returns to the task's defer.
        if operationPending { session.cancel(); editedText = "" }
        message = "Audioimport abgebrochen. Mikrofon geschlossen. Keine Datei wurde verändert."
    }

    /// No admission, file access or work until the user invokes a document action.
    func openTranscript() {
        guard canOpenTranscript, let admission = transcriptAdmission.begin() else { return }
        let generation = cancellationGeneration
        let selectedURL = environment.chooseTranscriptToOpen(uiLanguage)
        guard transcriptAdmission.permits(admission), generation == cancellationGeneration else {
            transcriptAdmission.finish(admission); resumeDeferredQuitSaveIfReady(); return
        }
        guard let url = selectedURL else {
            transcriptAdmission.finish(admission); recordReviewAction(.open, succeeded: false)
            resumeDeferredQuitSaveIfReady()
            return
        }
        let previousID = session.id, previousText = editedText
        operationPending = true; operationNeedsDrain = true
        task = Task {
            defer {
                transcriptAdmission.finish(admission); finishOperation(preservingMessage: true)
                resumeDeferredQuitSaveIfReady()
            }
            do {
                let read = environment.readTranscript
                let reading = Task.detached(priority: .utility) { try read(url) }
                let text = try await withTaskCancellationHandler {
                    try await reading.value
                } onCancel: { reading.cancel() }
                guard !Task.isCancelled, transcriptAdmission.permits(admission),
                      generation == cancellationGeneration else { return }
                // Do not overwrite edits made in another host while the read was pending.
                guard session.id == previousID,
                      TranscriptTextIdentity.matches(editedText, previousText) else {
                    message = "Öffnen nicht übernommen: Die Vorschau wurde inzwischen geändert."; return
                }
                if hasPendingReview || !editedText.isEmpty {
                    guard environment.confirmTranscriptReplacement(uiLanguage),
                          !Task.isCancelled, transcriptAdmission.permits(admission),
                          generation == cancellationGeneration,
                          session.id == previousID,
                          TranscriptTextIdentity.matches(editedText, previousText) else { return }
                }
                guard session.openTranscript(text) else { return }
                editedText = text; metrics = nil
                reviewRevisionCount = 0
                reviewRevisionSessionID = session.id
                savedReviewID = session.id; savedReviewText = text
                audioFileSession = false
                recordReviewAction(.open, succeeded: true)
                message = "Transkript geöffnet. Mikrofon geschlossen."
            } catch {
                guard !Task.isCancelled, generation == cancellationGeneration else { return }
                recordReviewAction(.open, succeeded: false)
                message = "Öffnen fehlgeschlagen. UTF-8-Klartext bis 4 MiB wählen. Die Vorschau bleibt erhalten."
            }
        }
    }
    func saveTranscript() { saveTranscript(forQuit: nil) }
    private func saveTranscript(forQuit attempt: UUID?) {
        // The owning Quit attempt holds only its decision flag. Every actual file,
        // capture and model admission must still have drained before a Save starts.
        guard (!isPresentationQA || launchConfiguration.isFunctionalQA), !quitRequested,
              !operationPending, !closePending, !modelOperationPending,
              !importAdmission.isHeld, !audioImportAdmission.isHeld, !transcriptAdmission.isHeld,
              !transcriptSavePreparation.isHeld,
              !environment.statisticsExportActive(),
              microphone.state == .closed, hasPendingReview,
              (attempt == nil ? !quitDecisionPending : quitAttempt == attempt),
              let preparation = transcriptSavePreparation.begin() else {
            if let attempt { finishQuitDecision(attempt) }
            return
        }
        let generation = cancellationGeneration
        let preparingReviewID = session.id
        defer {
            transcriptSavePreparation.finish(preparation)
            // Quit must observe the completed binding write, never its willSet
            // value. This only coalesces reentry during this synchronous Save.
            if quitAfterTranscriptSavePreparation {
                quitAfterTranscriptSavePreparation = false
                quit()
            }
        }
        guard commitPendingReviewText() else {
            if let attempt { finishQuitDecision(attempt) }
            message = "Speichern fehlgeschlagen. Die Vorschau bleibt erhalten."
            return
        }
        guard transcriptSavePreparation.permits(preparation), generation == cancellationGeneration,
              hasPendingReview, session.id == preparingReviewID, !quitRequested,
              (attempt == nil ? !quitDecisionPending : quitAttempt == attempt),
              !environment.statisticsExportActive(),
              let admission = transcriptAdmission.begin() else {
            if let attempt { finishQuitDecision(attempt) }
            return
        }
        // Retain preparation through @Published admission's willSet callbacks.
        guard transcriptSavePreparation.permits(preparation), generation == cancellationGeneration,
              transcriptAdmission.permits(admission), hasPendingReview,
              session.id == preparingReviewID, !quitRequested,
              (attempt == nil ? !quitDecisionPending : quitAttempt == attempt) else {
            transcriptAdmission.finish(admission)
            if let attempt { finishQuitDecision(attempt) }
            return
        }
        transcriptSavePreparation.finish(preparation)
        let text = editedText, reviewID = session.id
        let savedWordCount = LocalMetricsEvent.wordCount(text), savedRevisionCount = reviewRevisionCount
        let selectedURL = environment.chooseTranscriptToSave(uiLanguage)
        guard transcriptAdmission.permits(admission), generation == cancellationGeneration else {
            transcriptAdmission.finish(admission)
            if let attempt { finishQuitDecision(attempt) }
            resumeDeferredQuitSaveIfReady()
            return
        }
        guard let url = selectedURL else {
            transcriptAdmission.finish(admission)
            recordReviewAction(.save, succeeded: false,
                               editedWordCount: savedWordCount, editorRevisionCount: savedRevisionCount)
            if let attempt { finishQuitDecision(attempt) }
            resumeDeferredQuitSaveIfReady()
            return
        }
        guard transcriptAdmission.permits(admission), generation == cancellationGeneration,
              attempt == nil || (quitAttempt == attempt && session.id == reviewID &&
                  TranscriptTextIdentity.matches(editedText, text)) else {
            transcriptAdmission.finish(admission)
            if let attempt { finishQuitDecision(attempt) }
            resumeDeferredQuitSaveIfReady()
            return
        }
        operationPending = true; operationNeedsDrain = true
        task = Task {
            var saved = false
            defer {
                transcriptAdmission.finish(admission); finishOperation(preservingMessage: true)
                resumeDeferredQuitSaveIfReady()
                if let attempt, quitAttempt == attempt {
                    finishQuitDecision(attempt, releaseStatisticsExport: false)
                    // Publications above may synchronously admit edits in another
                    // host. Revalidate after them before requesting termination.
                    if saved, hasPendingReview, session.id == reviewID,
                       TranscriptTextIdentity.matches(editedText, text), !hasUnsavedReview {
                        beginQuit(preservingReview: true)
                    }
                    releaseStatisticsExportQuitSave()
                }
            }
            do {
                let write = environment.writeTranscript
                let writing = Task.detached(priority: .utility) { try write(text, url) }
                try await withTaskCancellationHandler {
                    try await writing.value
                } onCancel: { writing.cancel() }
                guard !Task.isCancelled, transcriptAdmission.permits(admission),
                      generation == cancellationGeneration, session.id == reviewID, hasPendingReview else { return }
                // Save marks the bytes actually written, never newer editor text.
                savedReviewID = reviewID; savedReviewText = text; saved = true
                recordReviewAction(.save, succeeded: true,
                                   editedWordCount: savedWordCount, editorRevisionCount: savedRevisionCount)
                message = TranscriptTextIdentity.matches(editedText, text)
                    ? "Transkript gespeichert. Die Vorschau bleibt erhalten."
                    : "Textstand gespeichert. Neuere Änderungen sind noch nicht gespeichert."
            } catch {
                guard !Task.isCancelled, generation == cancellationGeneration else { return }
                recordReviewAction(.save, succeeded: false,
                                   editedWordCount: savedWordCount, editorRevisionCount: savedRevisionCount)
                message = "Speichern fehlgeschlagen. Die Vorschau bleibt erhalten."
            }
        }
    }
    private func cancelTranscriptFile() {
        recordReviewAction(.cancel, succeeded: true)
        transcriptAdmission.invalidate(); cancellationGeneration &+= 1
        task?.cancel()
        // No capture exists for a file action. Preserve the entire review, even empty.
        message = "Dateivorgang abgebrochen. Die Vorschau bleibt erhalten. Ein bereits gestartetes Speichern kann abgeschlossen sein."
    }
    func unload() {
        guard !busy else { return }
        operationPending = true; operationNeedsDrain = true; modelOperationPending = true
        task = Task {
            // Successful memory-only work owns its message without changing the
            // dictation session. A fresh cancellation still finishes normally.
            defer { modelOperationPending = false; finishOperation(preservingMessage: !Task.isCancelled) }
            await inference.unload()
            guard !Task.isCancelled else { return }
            message = "Modell aus dem Arbeitsspeicher entladen."
        }
    }
    /// UI commands have one owner even when several presentation hosts are mounted.
    func setHotkeyEnabled(_ enabled: Bool) {
        guard !launchConfiguration.isQA else { configureHotkey(); return }
        guard !busy, !hotkeyRecording, !hotkeyRetirementInProgress,
              hotkeyEnabled != enabled else { return }
        hotkeyEnabled = enabled
        configureHotkey()
    }
    /// The recorder accepts no global key stream. A prior registration is
    /// temporarily suspended, but its enabled state/chord are saved for Cancel.
    func beginHotkeyRecording() -> Bool {
        guard !launchConfiguration.isQA, !busy, !quitRequested,
              !hotkeyRecording, !hotkeyIsDown, !hotkeyRetirementInProgress else { return false }
        guard !environment.secureInputEnabled() else {
            hotkeyStatus = "Sichere Eingabe ist aktiv; Tastenkürzelaufnahme nicht gestartet."
            return false
        }
        shortcutBeforeRecording = developmentShortcut
        hotkeyWasEnabledBeforeRecording = hotkeyEnabled
        hotkeyChordPending = false
        hotkeyRecording = true
        hotkeyGeneration &+= 1
        let generation = hotkeyGeneration
        hotkeyRegistrationReady = false
        let retired = hotkey; hotkey = nil
        retired?.unregister()
        guard generation == hotkeyGeneration, hotkeyRecording else { return false }
        hotkeyHeldSessionID = nil
        hotkeyStatus = "Drücke Ctrl–Shift oder Cmd–Shift mit Leertaste/F6–F19; Escape bricht ab."
        return true
    }
    /// The focused recorder reports held physical trigger keys to the common
    /// coordinator so Cancel/Quit from *either* mounted host cannot rearm early.
    func setHotkeyChordPending(_ pending: Bool) {
        guard hotkeyRecording else { return }
        hotkeyChordPending = pending
    }
    func cancelHotkeyRecording() {
        guard hotkeyRecording else { return }
        if hotkeyChordPending { abortHotkeyRecordingForPrivacy(); return }
        if environment.secureInputEnabled() { abortHotkeyRecordingForPrivacy(); return }
        let previous = shortcutBeforeRecording ?? developmentShortcut
        let restoreEnabled = hotkeyWasEnabledBeforeRecording
        hotkeyRecording = false; hotkeyChordPending = false; shortcutBeforeRecording = nil
        hotkeyWasEnabledBeforeRecording = false
        if developmentShortcut != previous { developmentShortcut = previous }
        if restoreEnabled {
            hotkeyEnabled = true
            let expectedGeneration = hotkeyGeneration &+ 1
            configureHotkey()
            guard hotkeyGeneration == expectedGeneration, !quitRequested else { return }
            hotkeyStatus = hotkeyEnabled
                ? "Tastenkürzelaufnahme abgebrochen; bisheriges Tastenkürzel wieder aktiv."
                : "Bisheriges Tastenkürzel konnte nicht wieder registriert werden. Hotkey aus."
        } else {
            hotkeyEnabled = false
            hotkeyStatus = "Tastenkürzelaufnahme abgebrochen; Hotkey bleibt aus."
        }
    }
    private func abortHotkeyRecordingForPrivacy() {
        guard hotkeyRecording else { return }
        let previous = shortcutBeforeRecording ?? developmentShortcut
        hotkeyRetirementInProgress = true
        hotkeyGeneration &+= 1
        hotkeyRegistrationReady = false
        hotkeyEnabled = false
        hotkeyIsDown = false; hotkeyHeldSessionID = nil
        hotkeyRecording = false; hotkeyChordPending = false; shortcutBeforeRecording = nil
        hotkeyWasEnabledBeforeRecording = false
        if developmentShortcut != previous { developmentShortcut = previous }
        let retired = hotkey; hotkey = nil
        retired?.unregister()
        hotkeyRetirementInProgress = false
        hotkeyStatus = "Tastenkürzelaufnahme durch Datenschutz-Unterbrechung beendet; Hotkey aus."
    }
    /// A rejected chord leaves the recorder open. Selection is persisted only
    /// after an allowed chord was accepted and (if formerly enabled) registered.
    @discardableResult
    func acceptRecordedHotkey(keyCode: UInt32, modifiers: UInt32) -> Bool {
        guard hotkeyRecording, !hotkeyChordPending, !workBusy, !quitRequested,
              !hotkeyRetirementInProgress else { return false }
        if environment.secureInputEnabled() { abortHotkeyRecordingForPrivacy(); return false }
        guard let selected = DevelopmentShortcut(keyCode: keyCode, modifiers: modifiers) else {
            hotkeyStatus = "Tastenkürzel reserviert oder nicht unterstützt. Wähle eine erlaubte Kombination."
            return false
        }
        let previous = shortcutBeforeRecording ?? developmentShortcut
        let restoreEnabled = hotkeyWasEnabledBeforeRecording
        hotkeyRecording = false; hotkeyChordPending = false; shortcutBeforeRecording = nil
        hotkeyWasEnabledBeforeRecording = false
        if !restoreEnabled {
            developmentShortcut = selected
            hotkeyEnabled = false
            hotkeyStatus = "Tastenkürzel gespeichert; globalen Hotkey bei Bedarf bewusst aktivieren."
            return true
        }
        // The old registration was suspended on Begin. Do not persist a chord
        // whose OS registration fails; make one best-effort restoration attempt.
        hotkeyGeneration &+= 1
        switch installHotkey(selected) {
        case .installed:
            developmentShortcut = selected
            hotkeyStatus = selected.title + " registriert (vorläufig)"
            return true
        case .superseded:
            return false
        case .failed:
            break
        }
        hotkeyGeneration &+= 1
        switch installHotkey(previous) {
        case .installed:
            hotkeyStatus = "Neues Tastenkürzel konnte nicht registriert werden; bisheriges ist wieder aktiv."
        case .superseded:
            return false
        case .failed:
            hotkeyEnabled = false
            hotkeyStatus = "Neues und bisheriges Tastenkürzel konnten nicht registriert werden. Hotkey aus."
        }
        return false
    }
    /// Compatibility for explicit preset selection while off; no enabled-state
    /// write or registration is inferred from this choice alone.
    func selectDevelopmentShortcut(_ shortcut: DevelopmentShortcut) {
        guard !launchConfiguration.isQA, !busy, !quitRequested,
              !hotkeyRecording, !hotkeyEnabled else { return }
        developmentShortcut = shortcut
    }
    func configureHotkey() {
        guard !hotkeyRetirementInProgress, (!busy || quitRequested) else { return }
        hotkeyGeneration &+= 1
        let generation = hotkeyGeneration
        hotkeyRegistrationReady = false
        let retired = hotkey; hotkey = nil
        retired?.unregister()
        guard generation == hotkeyGeneration else { return }
        hotkeyIsDown = false; hotkeyHeldSessionID = nil
        guard !launchConfiguration.isQA else {
            hotkeyEnabled = false; hotkeyStatus = "Globaler Hotkey ist im QA-Modus gesperrt"; return
        }
        guard !quitRequested else { hotkeyStatus = "App wird beendet; Hotkey bleibt aus"; return }
        guard !hotkeyRecording else { return }
        guard hotkeyEnabled else { hotkeyStatus = "Globaler Hotkey ist aus"; return }
        guard !environment.secureInputEnabled() else {
            hotkeyEnabled = false
            hotkeyStatus = "Sichere Eingabe ist aktiv; Hotkey bleibt aus."
            return
        }
        switch installHotkey(developmentShortcut) {
        case .installed:
            hotkeyStatus = developmentShortcut.title + " registriert (vorläufig)"
        case .superseded:
            return
        case .failed:
            hotkeyEnabled = false; hotkeyStatus = "Hotkey-Konflikt oder Registrierung fehlgeschlagen"
        }
    }
    private enum HotkeyInstallResult { case installed, failed, superseded }
    private func installHotkey(_ shortcut: DevelopmentShortcut) -> HotkeyInstallResult {
        let generation = hotkeyGeneration
        hotkeyRegistrationReady = false
        do {
            let registration = try environment.registerHotkey(shortcut) { [weak self] down in
                guard let self, generation == self.hotkeyGeneration,
                      self.hotkeyRegistrationReady,
                      self.hotkeyEnabled, !self.hotkeyRecording, !self.quitRequested else { return }
                self.receiveHotkeyEdge(down)
            }
            // A synchronous registrar can reenter privacy handling, Quit, or a
            // newer configuration before returning its handle. Retire that
            // stale handle without replacing the winner's registration/status.
            guard generation == hotkeyGeneration, hotkeyEnabled,
                  !hotkeyRecording, !quitRequested, !hotkeyRetirementInProgress else {
                registration.unregister()
                return .superseded
            }
            hotkey = registration
            hotkeyRegistrationReady = true
            return .installed
        } catch {
            guard generation == hotkeyGeneration, hotkeyEnabled,
                  !hotkeyRecording, !quitRequested, !hotkeyRetirementInProgress else {
                return .superseded
            }
            hotkey = nil; hotkeyRegistrationReady = false
            return .failed
        }
    }
    private func receiveHotkeyEdge(_ down: Bool) {
        if environment.secureInputEnabled() {
            hotkeyIsDown = false; hotkeyHeldSessionID = nil
            interruptForPrivacy(); return
        }
        if down {
            guard !hotkeyIsDown else { return }
            hotkeyIsDown = true
            if holdToTalk {
                let previousID = session.id
                start()
                // Failed admission (review, modal import, missing model, etc.)
                // must not let the later key-up stop unrelated work.
                if session.phase == .preparing, let startedID = session.id,
                   startedID != previousID {
                    if hotkeyIsDown { hotkeyHeldSessionID = startedID }
                    else { stop() } // Release reentered a synchronous startup boundary.
                }
            } else if session.phase == .recording { stop() }
            else { start() }
        } else {
            guard hotkeyIsDown else { return }
            hotkeyIsDown = false
            let startedID = hotkeyHeldSessionID
            hotkeyHeldSessionID = nil
            if let startedID, session.id == startedID,
               [.preparing, .recording].contains(session.phase) { stop() }
        }
    }
    private func startPrivacyWatchdog() {
        stopPrivacyWatchdog()
        cancelPrivacyWatchdog = environment.makeWatchdog { [weak self] in
            guard let self, self.session.phase.isBusy else { return }
            let permission = self.environment.permissionStatus()
            if self.environment.secureInputEnabled() || permission == .denied || permission == .restricted ||
                (self.session.phase != .preparing && permission != .authorized) {
                self.interruptForPrivacy()
            }
        }
    }
    private func stopPrivacyWatchdog() { cancelPrivacyWatchdog?(); cancelPrivacyWatchdog = nil }
    func quit() {
        if transcriptSavePreparation.isHeld {
            transcriptSavePreparation.invalidate()
            quitAfterTranscriptSavePreparation = true
            return
        }
        if hotkeyRecording { cancelHotkeyRecording() }
        guard !quitRequested, !quitDecisionPending, quitAttempt == nil else { return }
        if hasPendingReview, !commitPendingReviewTextBeforeQuit() { return }
        guard hasUnsavedReview else { beginQuit(); return }
        let attempt = UUID(), reviewID = session.id, text = editedText
        quitAttempt = attempt; quitDecisionPending = true
        let decision = environment.confirmUnsavedReviewQuit(uiLanguage)
        guard quitAttempt == attempt, hasPendingReview,
              session.id == reviewID, TranscriptTextIdentity.matches(editedText, text) else {
            finishQuitDecision(attempt); return
        }
        switch decision {
        case .cancel: finishQuitDecision(attempt)
        case .discard:
            finishQuitDecision(attempt); beginQuit()
        case .save:
            let exportPending = environment.beginStatisticsExportQuitSave()
            statisticsExportQuitSaveHeld = true
            // Keep modal re-entry coalesced while a cancelled read/import drains.
            // Cancel/Quit never accepts that worker's late replacement of this review.
            let pendingOperation = operationNeedsDrain ? task : nil
            let modalAdmissionPending = !operationNeedsDrain &&
                (transcriptAdmission.isHeld || (modelOperationPending && importAdmission.isHeld))
            if transcriptFilePending { cancelTranscriptFile() }
            else if modelOperationPending { cancelModelOperationPreservingReview() }
            if let pendingOperation {
                Task {
                    await pendingOperation.value
                    await environment.waitForStatisticsExportIdle()
                    guard quitAttempt == attempt, hasPendingReview,
                          session.id == reviewID,
                          TranscriptTextIdentity.matches(editedText, text) else {
                        finishQuitDecision(attempt); return
                    }
                    saveTranscript(forQuit: attempt)
                }
            } else if modalAdmissionPending || exportPending {
                deferredQuitSave = DeferredQuitSave(attempt: attempt, reviewID: reviewID, text: text)
                if exportPending {
                    Task {
                        await environment.waitForStatisticsExportIdle()
                        resumeDeferredQuitSaveIfReady()
                    }
                }
            } else { saveTranscript(forQuit: attempt) }
        }
    }
    private var statisticsExportQuitSaveHeld = false
    private func releaseStatisticsExportQuitSave() {
        guard statisticsExportQuitSaveHeld else { return }
        statisticsExportQuitSaveHeld = false
        environment.finishStatisticsExportQuitSave()
    }
    private func finishQuitDecision(_ attempt: UUID? = nil, releaseStatisticsExport: Bool = true) {
        guard attempt == nil || quitAttempt == attempt else { return }
        if let deferredQuitSave, attempt == nil || deferredQuitSave.attempt == attempt {
            self.deferredQuitSave = nil
        }
        quitAttempt = nil; quitDecisionPending = false
        if releaseStatisticsExport { releaseStatisticsExportQuitSave() }
    }
    private func resumeDeferredQuitSaveIfReady() {
        guard let deferredQuitSave,
              !transcriptAdmission.isHeld, !importAdmission.isHeld, !audioImportAdmission.isHeld,
              !environment.statisticsExportActive(),
              !operationPending, !modelOperationPending, !closePending else { return }
        guard quitAttempt == deferredQuitSave.attempt, hasPendingReview,
              session.id == deferredQuitSave.reviewID,
              TranscriptTextIdentity.matches(editedText, deferredQuitSave.text) else {
            finishQuitDecision(deferredQuitSave.attempt)
            return
        }
        self.deferredQuitSave = nil
        saveTranscript(forQuit: deferredQuitSave.attempt)
    }
    private func beginQuit(preservingReview: Bool = false) {
        guard !quitRequested else { return }
        quitRequested = true
        // The synchronous cut must precede any await or other publisher that
        // could let another mounted host admit a new export. Only an already
        // admitted writer may finish; its 0600 staging is drained below.
        let pendingStatisticsExport = environment.closeStatisticsExportsForQuit()
        // Resource-free permission waiting must not make Quit depend on a user answer.
        // The main-actor phase changes before the first resource-owning await.
        let pendingOperation = operationNeedsDrain ? task : nil
        cancel(preservingReview: preservingReview)
        hotkeyGeneration &+= 1
        hotkeyRegistrationReady = false
        let retired = hotkey; hotkey = nil
        retired?.unregister()
        Task {
            await capture.cancel(session: nil)
            // The cancelled import's bounded copy/hash loop owns and removes its temporary file.
            // Await that cleanup (or an in-flight decoder) before terminating the process.
            // A/B run in this actor turn; the drain is the only suspension between them.
            environment.quitWillAwaitAdmittedOperation()
            await pendingOperation?.value
            if let pendingStatisticsExport { _ = await pendingStatisticsExport.result }
            environment.quitWillUnloadInference()
            await inference.unload()
            if let localMetricsJournal { _ = await localMetricsJournal.synchronize() }
            // Synthetic QA owns only its generated files. Cleanup runs after all
            // admitted work drains; unknown entries are preserved on failure.
            if let context = functionalQAContext {
                do { try context.cleanup() }
                catch { message = "Synthetische QA-Dateien konnten nicht sicher entfernt werden; unbekannte Dateien bleiben erhalten." }
            }
            terminationReady = true
            environment.terminate()
        }
    }
}
