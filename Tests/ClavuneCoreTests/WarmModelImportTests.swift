import CryptoKit
import Foundation
import XCTest
@testable import ClavuneApp
@testable import ClavuneCore

/// Actual ModelStore copy/hash/recovery with tiny public bytes; no model engine,
/// production model directory, device, permission, panel or clipboard is used.
final class WarmModelImportTests: UIFixtureAssertions {
    private var root: URL!
    private var managed: URL!
    private var sources: [URL] = []
    private var candidates: [ModelCandidate] = []
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "Clavune.WarmModelImportTests." + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        root = project.appendingPathComponent(".build/warm-model-import-" + UUID().uuidString)
        managed = root.appendingPathComponent("managed")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (index, value) in ["abc", "xyz"].enumerated() {
            let bytes = Data(value.utf8)
            let source = root.appendingPathComponent("synthetic-\(index).bin")
            try bytes.write(to: source); sources.append(source)
            candidates.append(ModelCandidate(fileName: source.lastPathComponent, sizeBytes: Int64(bytes.count),
                sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                role: "synthetic", license: "MIT", qualityGate: "not-a-model"))
        }
    }
    override func tearDownWithError() throws {
        defaults?.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor private func fixture(
        importer: (@Sendable (URL) throws -> ModelStore.Installed)? = nil
    ) throws -> CoordinatorFixture {
        let directory = managed!, catalogue = candidates
        return try CoordinatorFixture(preferences: defaults, modelSelectionEnabled: false, configureEnvironment: { environment in
            environment.importManagedModel = importer ?? { url in
                XCTAssertFalse(Thread.isMainThread)
                return try ModelStore.importModel(url, into: directory, candidates: catalogue)
            }
        })
    }
    @MainActor private func importSource(_ url: URL, into fixture: CoordinatorFixture) async {
        fixture.chooseModel = { url }
        fixture.coordinator.importModel()
        let done = expectation(description: "Import drained")
        fixture.observeOperationFinished(done)
        await fulfillment(of: [done], timeout: 3)
        XCTAssertFalse(fixture.coordinator.operationPending)
        XCTAssertEqual(fixture.coordinator.microphone.state, .closed)
        XCTAssertEqual(fixture.resources.counts.value.opened, 0)
        XCTAssertEqual(fixture.inference.counts.value.loads, 0, "Import must not eagerly load")
        XCTAssertEqual(defaults.string(forKey: "selectedModelSHA256"), fixture.coordinator.model?.sha256)
    }

    @MainActor func testSameVerifiedSelectedFileSkipsUnloadAfterActualCopyAndHash() async throws {
        let fixture = try fixture()
        await importSource(sources[0], into: fixture)
        let unloads = fixture.inference.counts.value.unloads
        XCTAssertEqual(unloads, 1)
        let destination = managed.appendingPathComponent(candidates[0].sha256 + ".bin")
        let before = try FileManager.default.attributesOfItem(atPath: destination.path)[.systemFileNumber] as? NSNumber
        await importSource(sources[0], into: fixture)
        XCTAssertEqual(fixture.inference.counts.value.unloads, unloads)
        XCTAssertEqual(fixture.coordinator.model?.sha256, candidates[0].sha256)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: destination.path)[.systemFileNumber] as? NSNumber, before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ModelStore.recoveryBackupURL(in: managed).path))
        XCTAssertTrue(fixture.coordinator.canStart)
    }

    @MainActor func testDifferentVerifiedModelUnloadsEvenWhenItsManagedFileAlreadyExists() async throws {
        let fixture = try fixture()
        await importSource(sources[0], into: fixture)
        _ = try ModelStore.importModel(sources[1], into: managed, candidates: candidates)
        let unloads = fixture.inference.counts.value.unloads
        await importSource(sources[1], into: fixture)
        XCTAssertEqual(fixture.inference.counts.value.unloads, unloads + 1)
        XCTAssertEqual(fixture.coordinator.model?.sha256, candidates[1].sha256)
    }

    @MainActor func testSameHashAtDifferentManagedURLStillUnloads() async throws {
        let directory = managed!, catalogue = candidates
        let alternative = root.appendingPathComponent("other-managed")
        _ = try ModelStore.importModel(sources[0], into: alternative, candidates: catalogue)
        let useAlternative = FixtureValue(false)
        let fixture = try fixture(importer: { url in
            try ModelStore.importModel(url, into: useAlternative.value ? alternative : directory, candidates: catalogue)
        })
        await importSource(sources[0], into: fixture)
        useAlternative.value = true
        await importSource(sources[0], into: fixture)
        XCTAssertEqual(fixture.inference.counts.value.unloads, 2)
        XCTAssertEqual(fixture.coordinator.model?.sha256, candidates[0].sha256)
    }

    @MainActor func testSameHashRecoveryReplacesInodeAndStillUnloads() async throws {
        let fixture = try fixture()
        await importSource(sources[0], into: fixture)
        let destination = managed.appendingPathComponent(candidates[0].sha256 + ".bin")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        try Data("bad".utf8).write(to: destination)
        let previousInode = try FileManager.default.attributesOfItem(atPath: destination.path)[.systemFileNumber] as? NSNumber
        let unloads = fixture.inference.counts.value.unloads
        await importSource(sources[0], into: fixture)
        XCTAssertEqual(fixture.inference.counts.value.unloads, unloads + 1)
        XCTAssertNotEqual(try FileManager.default.attributesOfItem(atPath: destination.path)[.systemFileNumber] as? NSNumber, previousInode)
        XCTAssertEqual(try Data(contentsOf: destination), Data("abc".utf8))
        XCTAssertEqual(try Data(contentsOf: ModelStore.recoveryBackupURL(in: managed)), Data("bad".utf8))
    }

    @MainActor func testMutatedIncomingBytesFailWithoutChangingSelectionOrUnloading() async throws {
        let fixture = try fixture()
        await importSource(sources[0], into: fixture)
        let unloads = fixture.inference.counts.value.unloads
        try Data("bad".utf8).write(to: sources[0])
        await importSource(sources[0], into: fixture)
        XCTAssertEqual(fixture.coordinator.model?.sha256, candidates[0].sha256)
        XCTAssertEqual(fixture.inference.counts.value.unloads, unloads)
        XCTAssertEqual(fixture.coordinator.modelStatus, "Import fehlgeschlagen")
        XCTAssertEqual(try Data(contentsOf: managed.appendingPathComponent(candidates[0].sha256 + ".bin")), Data("abc".utf8))
    }

    @MainActor func testPickerCancellationPreservesSelectionAndCache() async throws {
        let fixture = try fixture()
        await importSource(sources[0], into: fixture)
        let status = fixture.coordinator.modelStatus
        let unloads = fixture.inference.counts.value.unloads
        fixture.chooseModel = { nil }; fixture.coordinator.importModel()
        XCTAssertFalse(fixture.coordinator.operationPending)
        XCTAssertEqual(fixture.coordinator.model?.sha256, candidates[0].sha256)
        XCTAssertEqual(fixture.coordinator.modelStatus, status)
        XCTAssertEqual(fixture.inference.counts.value.unloads, unloads)
    }

    @MainActor func testCancelledImportDrainsRejectsLateDifferentModelAndPreservesPriorCache() async throws {
        let directory = managed!, catalogue = candidates
        let entered = expectation(description: "Second importer entered")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let calls = FixtureValue(0), cancelled = FixtureValue(false)
        let fixture = try fixture(importer: { url in
            let result = try ModelStore.importModel(url, into: directory, candidates: catalogue)
            calls.update { $0 += 1 }
            if calls.value == 2 {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 5)
                cancelled.value = Task.isCancelled
                // Deliberately return a valid but stale success after cancellation.
            }
            return result
        })
        await importSource(sources[0], into: fixture)
        let unloads = fixture.inference.counts.value.unloads
        let source = sources[1]; fixture.chooseModel = { source }
        fixture.coordinator.importModel()
        await fulfillment(of: [entered], timeout: 2)
        let done = expectation(description: "Cancelled worker drained")
        fixture.observeOperationFinished(done)
        fixture.coordinator.cancel()
        let closed = expectation(description: "Capture close acknowledged")
        fixture.observeCloseFinished(closed)
        XCTAssertTrue(fixture.coordinator.busy)
        fixture.coordinator.importModel(); fixture.coordinator.start()
        release.signal()
        await fulfillment(of: [done, closed], timeout: 3)
        XCTAssertTrue(cancelled.value)
        XCTAssertEqual(defaults.string(forKey: "selectedModelSHA256"), candidates[0].sha256)
        XCTAssertEqual(calls.value, 2)
        XCTAssertEqual(fixture.coordinator.model?.sha256, candidates[0].sha256)
        XCTAssertEqual(fixture.inference.counts.value.unloads, unloads)
        XCTAssertEqual(fixture.resources.counts.value.opened, 0)
    }

    @MainActor func testCancelledSameHashRecoveryDrainsOldCacheBeforeRetryCanReuseReplacement() async throws {
        let directory = managed!, catalogue = candidates
        let recovered = expectation(description: "Actual same-SHA recovery completed before cancellation")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let calls = FixtureValue(0), cancelled = FixtureValue(false)
        let fixture = try fixture(importer: { url in
            let installed = try ModelStore.importModel(url, into: directory, candidates: catalogue)
            calls.update { $0 += 1 }
            if calls.value == 2 {
                XCTAssertFalse(installed.reusedVerifiedFile, "Recovery must not claim inode reuse")
                recovered.fulfill()
                _ = release.wait(timeout: .now() + 5)
                cancelled.value = Task.isCancelled
            } else if calls.value == 3 {
                XCTAssertTrue(installed.reusedVerifiedFile, "Retry sees the already-repaired file")
            }
            return installed
        })
        await importSource(sources[0], into: fixture)
        let destination = managed.appendingPathComponent(candidates[0].sha256 + ".bin")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        try Data("bad".utf8).write(to: destination)
        let oldInode = try FileManager.default.attributesOfItem(atPath: destination.path)[.systemFileNumber] as? NSNumber
        let before = fixture.inference.counts.value.unloads
        let source = sources[0]; fixture.chooseModel = { source }
        fixture.coordinator.importModel()
        await fulfillment(of: [recovered], timeout: 2)
        XCTAssertNotEqual(try FileManager.default.attributesOfItem(atPath: destination.path)[.systemFileNumber] as? NSNumber, oldInode)
        XCTAssertEqual(try Data(contentsOf: destination), Data("abc".utf8))
        XCTAssertEqual(try Data(contentsOf: ModelStore.recoveryBackupURL(in: managed)), Data("bad".utf8))
        fixture.inference.unloadGate = ControlledDelivery()
        fixture.inference.onUnload = expectation(description: "Cancelled repair invalidates the old context")
        let done = expectation(description: "Cancelled repair and invalidation drained")
        fixture.observeOperationFinished(done)
        fixture.coordinator.cancel()
        let closed = expectation(description: "Capture close acknowledged")
        fixture.observeCloseFinished(closed)
        release.signal()
        await fulfillment(of: [fixture.inference.onUnload!], timeout: 2)
        guard fixture.inference.counts.value.unloads == before + 1 else {
            XCTFail("Cancelled recovery retained the pre-repair context")
            return // A broken candidate must fail, not wait forever on an unentered gate.
        }
        await fixture.inference.unloadGate?.waitUntilSuspended()
        XCTAssertTrue(fixture.coordinator.operationPending, "Invalidation must drain before admission releases")
        XCTAssertTrue(fixture.coordinator.busy)
        fixture.coordinator.importModel(); fixture.coordinator.start()
        XCTAssertEqual(calls.value, 2)
        await fixture.inference.unloadGate?.release()
        await fulfillment(of: [done, closed], timeout: 3)
        XCTAssertTrue(cancelled.value)
        XCTAssertEqual(fixture.inference.counts.value.unloads, before + 1)
        XCTAssertEqual(fixture.coordinator.model?.sha256, candidates[0].sha256)
        XCTAssertEqual(defaults.string(forKey: "selectedModelSHA256"), candidates[0].sha256)
        XCTAssertTrue(fixture.coordinator.modelStatus.contains("Import abgebrochen"))
        XCTAssertEqual(fixture.resources.counts.value.opened, 0)
        fixture.inference.unloadGate = nil; fixture.inference.onUnload = nil
        await importSource(sources[0], into: fixture)
        XCTAssertEqual(calls.value, 3)
        XCTAssertEqual(fixture.inference.counts.value.unloads, before + 1,
            "Retry may now skip unload only because the old context has already drained")
    }

    @MainActor func testCancellationDuringDifferentModelUnloadRejectsLateSelection() async throws {
        let fixture = try fixture()
        await importSource(sources[0], into: fixture)
        fixture.inference.unloadGate = ControlledDelivery()
        fixture.inference.onUnload = expectation(description: "Switch unload entered")
        let source = sources[1]; fixture.chooseModel = { source }
        fixture.coordinator.importModel()
        await fulfillment(of: [fixture.inference.onUnload!], timeout: 2)
        await fixture.inference.unloadGate?.waitUntilSuspended()
        let done = expectation(description: "Cancelled unload drained")
        fixture.observeOperationFinished(done)
        fixture.coordinator.cancel()
        let closed = expectation(description: "Capture close acknowledged")
        fixture.observeCloseFinished(closed)
        XCTAssertTrue(fixture.coordinator.operationPending)
        await fixture.inference.unloadGate?.release()
        await fulfillment(of: [done, closed], timeout: 3)
        XCTAssertEqual(fixture.coordinator.model?.sha256, candidates[0].sha256)
        XCTAssertFalse(fixture.coordinator.busy)
        XCTAssertEqual(defaults.string(forKey: "selectedModelSHA256"), candidates[0].sha256)
        // Once an already-admitted unload starts, cache preservation is impossible;
        // selection remains old and the next job must load it again.
        XCTAssertEqual(fixture.inference.counts.value.unloads, 2)
    }
}
