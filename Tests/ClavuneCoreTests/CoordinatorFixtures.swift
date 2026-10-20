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
    }
    let id: UUID
    var onFinished: (() -> Void)?
    private let configuration: CaptureRunConfiguration
    private let resources: Resources
    private var closed = false
    init(_ configuration: CaptureRunConfiguration, resources: Resources) {
        self.id = configuration.id; self.configuration = configuration; self.resources = resources
        resources.counts.update { $0.constructed += 1 }
    }
    func prepare() { resources.counts.update { $0.prepared += 1 }; resources.duringPrepare?() }
    func start() {
        resources.counts.update { $0.opened += 1 }; resources.duringOpen?()
        if resources.failDuringOpen { abort(.audioUnavailable) }
    }
    func beginPumping() {
        resources.counts.update { $0.pumped += 1 }
        // Match the real serial pump: startup resolves before its queued sample work.
        configuration.queue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.configuration.onFirst()
        }
    }
    func stop(cutoff: UInt64, completion: CheckedContinuation<CapturedAudio, Error>) {
        resources.counts.update { $0.stopCutoffs.append(cutoff) }
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
    func abort(_ error: DictationError) {
        guard !closed else { return }
        shutdown(); configuration.onFailure(error); onFinished?()
    }
}

final class FixtureInference: InferenceServicing, @unchecked Sendable {
    struct Counts { var loads = 0, decodes = 0, unloads = 0 }
    let counts = FixtureValue(Counts())
    var loadGate: ControlledDelivery?
    var unloadGate: ControlledDelivery?
    var onLoad: XCTestExpectation?
    var onUnload: XCTestExpectation?
    func load(url: URL, candidate: ModelCandidate) async throws -> (warm: Bool, seconds: Double) {
        counts.update { $0.loads += 1 }; onLoad?.fulfill()
        if let loadGate { await loadGate.suspend() }
        return (true, 0)
    }
    func transcribe(_ pcm: SessionPCM, language: LanguageMode, cancellation: DecodeCancellation,
                    policy: ResourcePolicy) async throws -> TranscriptionResult {
        counts.update { $0.decodes += 1 }
        return TranscriptionResult(text: "Kein privates Audio: generiertes Testergebnis.", languageID: 1, decodeSeconds: 0)
    }
    func unload() async {
        counts.update { $0.unloads += 1 }; onUnload?.fulfill()
        if let unloadGate { await unloadGate.suspend() }
    }
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
    let inference = FixtureInference()
    let privacy = FixtureValue(true)
    let permission = FixturePermission()
    var permissionStatus: AVAuthorizationStatus = .authorized
    var now: UInt64 = 100
    var pickerCalls = 0, terminationCalls = 0, permissionCalls = 0
    var terminated: XCTestExpectation?
    var throwCancellationAllocation = false
    var coordinator: AppCoordinator!
    var observations: [AnyCancellable] = []

    init() throws {
        let privacy = privacy, queue = queue, resources = resources
        let capture = CaptureService(queue: queue.queue, enqueue: { queue.enqueue($0) },
            privacyAllowsCapture: { privacy.value }, makeRun: { FixtureCaptureRun($0, resources: resources) })
        let environment = CoordinatorEnvironment(nowHostTime: { [unowned self] in self.now },
            secureInputEnabled: { !privacy.value }, permissionStatus: { [unowned self] in self.permissionStatus },
            requestPermission: { [unowned self] in self.permissionCalls += 1; return await self.permission.request() },
            inputDevices: { [] }, chooseModel: { [unowned self] in self.pickerCalls += 1; return nil },
            makeCancellation: { [unowned self] in
                if self.throwCancellationAllocation { throw DictationError.inferenceFailed }
                return try DecodeCancellation()
            }, makeWatchdog: { _ in {} }, workspaceNotifications: nil,
            terminate: { [unowned self] in self.terminationCalls += 1; self.terminated?.fulfill() })
        let candidate = try XCTUnwrap(ModelStore.candidates().first)
        coordinator = AppCoordinator(policy: try ResourcePolicy.bundled(), capture: capture,
            inference: inference, environment: environment,
            modelSelection: (candidate, URL(fileURLWithPath: "/fixture-model-never-opened")))
    }
    func observePhase(_ phase: SessionPhase, expectation: XCTestExpectation) {
        coordinator.$session.filter { $0.phase == phase }.prefix(1)
            .sink { _ in expectation.fulfill() }.store(in: &observations)
    }
    func observeOperationFinished(_ expectation: XCTestExpectation) {
        coordinator.$operationPending.filter { !$0 }.prefix(1)
            .sink { _ in expectation.fulfill() }.store(in: &observations)
    }
    func observeCloseFinished(_ expectation: XCTestExpectation) {
        coordinator.$closePending.filter { !$0 }.prefix(1)
            .sink { _ in expectation.fulfill() }.store(in: &observations)
    }
}
