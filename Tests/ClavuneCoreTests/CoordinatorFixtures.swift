import AppKit
import AVFoundation
import Combine
import CoreAudio
import Foundation
import XCTest
@testable import ClavuneApp
@testable import ClavuneCore

/// Serial delivery can be paused; production CaptureService still owns every control decision.
final class ControlledCaptureQueue: @unchecked Sendable {
    let queue = DispatchQueue(label: "clavune.fixture.capture")
    private let lock = NSLock()
    private var paused = false
    private var pending: [@Sendable () -> Void] = []
    private var nextSubmission: XCTestExpectation?
    func pause(nextSubmission: XCTestExpectation? = nil) {
        lock.lock(); paused = true; self.nextSubmission = nextSubmission; lock.unlock()
    }
    func enqueue(_ work: @escaping @Sendable () -> Void) {
        lock.lock()
        if paused { pending.append(work) } else { queue.async(execute: work) }
        let signal = nextSubmission; nextSubmission = nil
        lock.unlock(); signal?.fulfill()
    }
    func resume() {
        lock.lock()
        for work in pending { queue.async(execute: work) }
        pending.removeAll(); paused = false; lock.unlock()
    }
}

final class FixtureValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
    func update(_ change: (inout Value) -> Void) { lock.lock(); defer { lock.unlock() }; change(&storage) }
}

/// In-memory boundary only: never opens any system pasteboard.
@MainActor
final class FixtureClipboardSink: ClipboardWriteSink {
    enum Call: Equatable {
        case prepare(NSPasteboard.ContentsOptions)
        case write(String, NSPasteboard.PasteboardType)
    }
    var calls: [Call] = []
    var acceptsWrite = true
    func prepareForNewContents(with options: NSPasteboard.ContentsOptions) { calls.append(.prepare(options)) }
    func setString(_ text: String, forType type: NSPasteboard.PasteboardType) -> Bool {
        calls.append(.write(text, type)); return acceptsWrite
    }
}

/// Same single MainActor task as the production dispatcher, retaining only its handle.
/// The handle acknowledges completion even when the supplied guard returns early.
/// No callback body, admission policy, timer, or queue sentinel is reproduced here.
final class FixtureProgressDispatcher: @unchecked Sendable {
    struct Submission: Sendable {
        let ordinal: UInt64
        let task: Task<Void, Never>
    }
    private let lock = NSLock()
    private var nextOrdinal: UInt64 = 0
    private var pending: [Submission] = []

    func dispatch(_ work: @escaping @MainActor @Sendable () -> Void) {
        let task = Task { @MainActor in work() }
        lock.lock(); defer { lock.unlock() }
        nextOrdinal += 1
        pending.append(Submission(ordinal: nextOrdinal, task: task))
    }

    func takeSubmissions() -> [Submission] {
        lock.lock(); defer { lock.unlock() }
        let submissions = pending
        pending.removeAll()
        return submissions
    }
}

/// Fake hardware/pump resource. It does not reproduce CaptureService admission or stop delivery.
final class FixtureCaptureRun: CaptureRunning, @unchecked Sendable {
    struct Counts {
        var constructed = 0, prepared = 0, opened = 0, pumped = 0, closed = 0
        var stopCutoffs: [UInt64] = []
    }
    final class Resources: @unchecked Sendable {
        let counts = FixtureValue(Counts())
        var duringPrepare: (@Sendable () -> Void)?
        var duringOpen: (@Sendable () -> Void)?
        var failDuringOpen = false
        var automaticallyDeliverFirstSample = true
        var limitOnBegin: UInt64?
        var duringLimitOnBegin: (@Sendable () -> Void)?
        // Retain the actual coordinator callbacks, including after fake resource shutdown.
        // This is deliberate fault injection, not a second capture/admission implementation.
        struct Callbacks: Sendable {
            let first: @Sendable () -> Void
            let progress: @Sendable (Double, Float) -> Void
            let failure: @Sendable (DictationError) -> Void
            let limit: @Sendable (CaptureStopRequest) -> Void
        }
        let limitActions = FixtureValue<[UUID: @Sendable (UInt64) -> Void]>([:])
        let failureActions = FixtureValue<[UUID: @Sendable (DictationError) -> Void]>([:])
        func reachLimit(session: UUID, cutoff: UInt64) { limitActions.value[session]?(cutoff) }
        func fail(session: UUID, error: DictationError) { failureActions.value[session]?(error) }
        let callbacks = FixtureValue<[UUID: Callbacks]>([:])
        func progress(session: UUID, seconds: Double, peak: Float) {
            callbacks.value[session]?.progress(seconds, peak)
        }
        func firstSample(session: UUID) { callbacks.value[session]?.first() }
    }
    let id: UUID
    var onFinished: (() -> Void)?
    private let configuration: CaptureRunConfiguration
    private let resources: Resources
    private var closed = false
    private var limitHandoff = CaptureLimitHandoff()
    init(_ configuration: CaptureRunConfiguration, resources: Resources) {
        self.id = configuration.id; self.configuration = configuration; self.resources = resources
        resources.counts.update { $0.constructed += 1 }
        resources.callbacks.update {
            precondition($0.count < 8, "Each fixture keeps at most eight synthetic sessions")
            $0[configuration.id] = Resources.Callbacks(first: configuration.onFirst,
                progress: configuration.onProgress, failure: configuration.onFailure, limit: configuration.onLimitReached)
        }
        resources.limitActions.update { actions in
            actions[id] = { [weak self] cutoff in
                configuration.queue.async { [weak self] in self?.finishAtLimit(cutoff: cutoff) }
            }
        }
        resources.failureActions.update { actions in
            actions[id] = { [weak self] error in
                configuration.queue.async { [weak self] in self?.abort(error) }
            }
        }
    }
    func prepare() { resources.counts.update { $0.prepared += 1 }; resources.duringPrepare?() }
    func start() {
        resources.counts.update { $0.opened += 1 }; resources.duringOpen?()
        if resources.failDuringOpen { abort(.audioUnavailable) }
    }
    func beginPumping() {
        resources.counts.update { $0.pumped += 1 }
        if let cutoff = resources.limitOnBegin {
            finishAtLimit(cutoff: cutoff); resources.duringLimitOnBegin?(); return
        }
        // Match the real serial pump: startup resolves before its queued sample work.
        configuration.queue.async { [weak self] in
            guard let self, !self.closed, self.resources.automaticallyDeliverFirstSample else { return }
            self.configuration.onFirst()
        }
    }
    func stop(cutoff: UInt64, completion: CheckedContinuation<CapturedAudio, Error>) {
        resources.counts.update { $0.stopCutoffs.append(cutoff) }
        if limitHandoff.isPending {
            do { completion.resume(returning: try limitHandoff.take(cutoffHostTime: cutoff)) }
            catch { completion.resume(throwing: error) }
            onFinished?(); return
        }
        guard !closed else { completion.resume(throwing: DictationError.noAudio); return }
        shutdown()
        // Result supplied by the resource boundary, without a second stop implementation.
        completion.resume(returning: CapturedAudio(pcm: SessionPCM(samples: [0, 0]),
            firstHostTime: 1, stopHostTime: cutoff, closedHostTime: cutoff + 1, nativeRate: 24000))
        onFinished?()
    }
    func shutdown() {
        guard !closed else { return }; closed = true
        resources.counts.update { $0.closed += 1 }
    }
    private func finishAtLimit(cutoff: UInt64) {
        guard !closed else { return }
        shutdown()
        do {
            try limitHandoff.publish(CapturedAudio(pcm: SessionPCM(samples: [0.1, 0.2]),
                firstHostTime: 1, stopHostTime: cutoff, closedHostTime: cutoff + 1, nativeRate: 24000,
                completionReason: .sessionLimit))
            configuration.onLimitReached(CaptureStopRequest(session: id, cutoffHostTime: cutoff))
        } catch { configuration.onFailure(.audioUnavailable); onFinished?() }
    }
    func abort(_ error: DictationError) {
        if closed {
            if error == .cancelled, limitHandoff.isPending { limitHandoff.cancel(); onFinished?() }
            return
        }
        shutdown(); limitHandoff.cancel(); configuration.onFailure(error); onFinished?()
    }
}

final class FixtureInference: InferenceServicing, @unchecked Sendable {
    struct Counts { var loads = 0, decodes = 0, unloads = 0 }
    let counts = FixtureValue(Counts())
    var transcript = "Kein privates Audio: generiertes Testergebnis."
    let receivedPCM = FixtureValue<[Float]>([])
    let receivedLanguage = FixtureValue<LanguageMode?>(nil)
    var loadFailure: DictationError?
    var decodeFailure: DictationError?
    var loadGate: ControlledDelivery?
    var unloadGate: ControlledDelivery?
    var decodeGate: ControlledDelivery?
    var onDecode: XCTestExpectation?
    var onLoad: XCTestExpectation?
    var onUnload: XCTestExpectation?
    var onUnloadCompleted: (@MainActor @Sendable () -> Void)?
    func load(url: URL, candidate: ModelCandidate) async throws -> (warm: Bool, seconds: Double) {
        counts.update { $0.loads += 1 }; onLoad?.fulfill()
        if let loadGate { await loadGate.suspend() }
        if let loadFailure { throw loadFailure }
        return (true, 0)
    }
    func transcribe(_ pcm: SessionPCM, language: LanguageMode, cancellation: DecodeCancellation,
                    policy: ResourcePolicy) async throws -> TranscriptionResult {
        receivedPCM.value = pcm.samples; receivedLanguage.value = language
        counts.update { $0.decodes += 1 }; onDecode?.fulfill()
        if let decodeGate { await decodeGate.suspend() }
        if let decodeFailure { throw decodeFailure }
        return TranscriptionResult(text: transcript, languageID: 1, decodeSeconds: 0)
    }
    func unload() async {
        counts.update { $0.unloads += 1 }; onUnload?.fulfill()
        if let unloadGate { await unloadGate.suspend() }
        await onUnloadCompleted?()
    }
}

/// No global shortcut registration, event handler installation, or settings writes.
@MainActor
final class FixtureHotkeyRegistrar {
    enum RegistrationError: Error { case conflict }
    @MainActor
    final class Registration: HotkeyRegistration {
        private(set) var unregisterCalls = 0
        private(set) var active = true
        var onUnregister: (() -> Void)?
        private let action: (Bool) -> Void
        init(action: @escaping (Bool) -> Void) { self.action = action }
        func unregister() {
            unregisterCalls += 1; active = false
            let callback = onUnregister; onUnregister = nil
            callback?()
        }
        // Synthetic routing only; no claim about Carbon repeat suppression or event delivery.
        func send(down: Bool) { if active { action(down) } }
        // A callback may already have been queued when its registration retires.
        func deliverAlreadyQueued(down: Bool) { action(down) }
    }
    var failuresRemaining = 0
    var blockedShortcuts: [DevelopmentShortcut] = []
    private(set) var shortcuts: [DevelopmentShortcut] = []
    private(set) var registrations: [Registration] = []
    var activeCount: Int { registrations.filter { $0.active }.count }
    func register(_ shortcut: DevelopmentShortcut, action: @escaping (Bool) -> Void) throws -> any HotkeyRegistration {
        shortcuts.append(shortcut)
        if blockedShortcuts.contains(shortcut) { throw RegistrationError.conflict }
        if failuresRemaining > 0 {
            failuresRemaining -= 1; throw RegistrationError.conflict
        }
        let registration = Registration(action: action)
        registrations.append(registration)
        return registration
    }
}

/// A cancelled timer may already have enqueued an actor action. Keep these concepts separate.
@MainActor
final class FixtureWatchdog {
    @MainActor
    final class Handle {
        private(set) var active = true
        private(set) var cancellationCalls = 0
        private let action: @MainActor () -> Void
        init(action: @escaping @MainActor () -> Void) { self.action = action }
        func cancel() { cancellationCalls += 1; active = false }
        func fireActiveTimer() { if active { action() } }
        func deliverAlreadyQueuedTick() { action() }
    }
    private(set) var handles: [Handle] = []
    var activeCount: Int { handles.filter { $0.active }.count }
    func make(_ action: @escaping @MainActor () -> Void) -> () -> Void {
        precondition(handles.count < 8, "Each fixture keeps at most eight synthetic timers")
        let handle = Handle(action: action); handles.append(handle)
        return { handle.cancel() }
    }
}

enum FixtureQuitEvent: Equatable {
    case willAwaitAdmittedOperation
    case admittedWorkSettled
    case willUnloadInference
    case unloadCompleted
    case terminationRequested
}

@MainActor
final class FixturePermission {
    var requested: XCTestExpectation?
    private(set) var pending = false
    private var continuation: CheckedContinuation<Bool, Never>?
    func request() async -> Bool {
        await withCheckedContinuation {
            continuation = $0; pending = true; requested?.fulfill()
        }
    }
    func resolve(_ granted: Bool) {
        pending = false; continuation?.resume(returning: granted); continuation = nil
    }
}

@MainActor
final class CoordinatorFixture {
    let queue = ControlledCaptureQueue()
    let resources = FixtureCaptureRun.Resources()
    let clipboard = FixtureClipboardSink()
    let inference = FixtureInference()
    let hotkeyRegistrar = FixtureHotkeyRegistrar()
    let watchdog = FixtureWatchdog()
    let progressDispatcher = FixtureProgressDispatcher()
    let lifecycleDispatcher = FixtureProgressDispatcher()
    var chooseModel: (@MainActor () -> URL?)?
    let privacy = FixtureValue(true)
    let permission = FixturePermission()
    var permissionStatus: AVAuthorizationStatus = .authorized
    var now: UInt64 = 100
    var pickerCalls = 0, terminationCalls = 0, permissionCalls = 0
    var terminated: XCTestExpectation?
    var quitWillAwaitAdmittedOperation: XCTestExpectation?
    var quitTrace: [FixtureQuitEvent] = []
    var throwCancellationAllocation = false
    var cancellationAllocationCalls = 0
    var coordinator: AppCoordinator!
    var observations: [AnyCancellable] = []

    init(preferences: UserDefaults? = nil, launchConfiguration: AppLaunchConfiguration = .production,
         modelSelectionEnabled: Bool = true,
         localMetricsJournal: LocalMetricsJournal? = nil,
         processUsageSnapshot: @escaping @MainActor () -> LocalProcessUsageSnapshot? = { LocalProcessUsageSnapshot.capture() },
         configureEnvironment: @MainActor (inout CoordinatorEnvironment) -> Void = { _ in },
         workspaceNotifications: NotificationCenter? = nil,
         restoreManagedSelection: @escaping @Sendable (String) throws -> ModelStore.Installed = { _ in
             throw DictationError.modelInvalid
         }) throws {
        let privacy = privacy, queue = queue, resources = resources
        let progressDispatcher = progressDispatcher, lifecycleDispatcher = lifecycleDispatcher
        let capture = CaptureService(queue: queue.queue, enqueue: { queue.enqueue($0) },
            privacyAllowsCapture: { privacy.value }, makeRun: { FixtureCaptureRun($0, resources: resources) })
        var environment = CoordinatorEnvironment(nowHostTime: { [unowned self] in self.now },
            secureInputEnabled: { !privacy.value }, permissionStatus: { [unowned self] in self.permissionStatus },
            requestPermission: { [unowned self] in self.permissionCalls += 1; return await self.permission.request() },
            inputDevices: { [] }, chooseModel: { [unowned self] in
                self.pickerCalls += 1; return self.chooseModel?()
            },
            makeCancellation: { [unowned self] in
                self.cancellationAllocationCalls += 1
                if self.throwCancellationAllocation { throw DictationError.inferenceFailed }
                return try DecodeCancellation()
            }, makeWatchdog: { [unowned self] action in self.watchdog.make(action) }, workspaceNotifications: workspaceNotifications,
            terminate: { [unowned self] in
                self.quitTrace.append(.terminationRequested)
                self.terminationCalls += 1; self.terminated?.fulfill()
            }, registerHotkey: { [unowned self] shortcut, action in
                try self.hotkeyRegistrar.register(shortcut, action: action)
            }, quitWillAwaitAdmittedOperation: { [unowned self] in
                self.quitTrace.append(.willAwaitAdmittedOperation)
                self.quitWillAwaitAdmittedOperation?.fulfill()
            }, quitWillUnloadInference: { [unowned self] in
                self.quitTrace.append(.willUnloadInference)
            }, dispatchCaptureProgress: { progressDispatcher.dispatch($0) },
            dispatchCaptureLifecycle: { lifecycleDispatcher.dispatch($0) },
            copyText: { [unowned self] in LocalClipboard.copy($0, using: self.clipboard) },
            restoreManagedSelection: restoreManagedSelection)
        // Historical resource-drain fixtures deliberately discard their synthetic
        // review on Quit. New document-policy fixtures override this explicitly.
        environment.confirmUnsavedReviewQuit = { _ in .discard }
        configureEnvironment(&environment)
        inference.onUnloadCompleted = { [unowned self] in self.quitTrace.append(.unloadCompleted) }
        let candidate = try XCTUnwrap(ModelStore.candidates().first)
        coordinator = AppCoordinator(policy: try ResourcePolicy.bundled(), capture: capture,
            inference: inference, environment: environment, preferences: preferences, launchConfiguration: launchConfiguration,
            modelSelection: modelSelectionEnabled ? (candidate, URL(fileURLWithPath: "/fixture-model-never-opened")) : nil,
            localMetricsJournal: localMetricsJournal, processUsageSnapshot: processUsageSnapshot)
    }
    func observePhase(_ phase: SessionPhase, expectation: XCTestExpectation) {
        coordinator.$session.filter { $0.phase == phase }.prefix(1)
            .sink { _ in expectation.fulfill() }.store(in: &observations)
    }
    func observeOperationFinished(_ expectation: XCTestExpectation) {
        coordinator.$operationPending.filter { !$0 }.prefix(1)
            .sink { _ in expectation.fulfill() }.store(in: &observations)
    }
    func observeAdmittedWorkSettled(_ expectation: XCTestExpectation) {
        // finishOperation publishes synchronously in the admitted task's final defer.
        coordinator.$operationPending.filter { !$0 }.prefix(1)
            .sink { [unowned self] _ in
                self.quitTrace.append(.admittedWorkSettled); expectation.fulfill()
            }.store(in: &observations)
    }
    func observeCloseFinished(_ expectation: XCTestExpectation) {
        coordinator.$closePending.filter { !$0 }.prefix(1)
            .sink { _ in expectation.fulfill() }.store(in: &observations)
    }
}
