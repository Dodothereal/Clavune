import AVFoundation
import Combine
import Darwin
import Foundation
import XCTest
@testable import ClavuneApp
@testable import ClavuneCore

/// No real model, microphone, clipboard, OS picker, hotkey or user document.
final class FunctionalQAContextTests: XCTestCase {
    private func configuration() throws -> AppLaunchConfiguration {
        try AppLaunchConfiguration.parse(environment: ["CLAVUNE_QA_PROFILE": "functional-" + String(UUID().uuidString.prefix(12)),
            "CLAVUNE_QA_FUNCTIONAL": "synthetic-v1"])
    }
    private func nativePanelConfiguration() throws -> AppLaunchConfiguration {
        try AppLaunchConfiguration.parse(environment: [
            "CLAVUNE_QA_PROFILE": "native-panel-" + String(UUID().uuidString.prefix(12)),
            "CLAVUNE_QA_FUNCTIONAL": "synthetic-v1",
            "CLAVUNE_QA_NATIVE_PANELS": "synthetic-v1"])
    }
    @MainActor private func waitForOperation(_ coordinator: AppCoordinator) async {
        guard coordinator.operationPending else { return }
        let done = expectation(description: "synthetic operation drained")
        let observation = coordinator.$operationPending.filter { !$0 }.prefix(1).sink { _ in done.fulfill() }
        let outcome = await XCTWaiter.fulfillment(of: [done], timeout: 3)
        XCTAssertEqual(outcome, .completed)
        observation.cancel()
    }
    @MainActor func testContextRequiresExplicitFunctionalOptIn() throws {
        XCTAssertThrowsError(try FunctionalQAContext(configuration: .production))
        let presentation = try AppLaunchConfiguration.parse(environment: ["CLAVUNE_QA_PROFILE": "presentation-only"])
        XCTAssertThrowsError(try FunctionalQAContext(configuration: presentation))
    }
    @MainActor func testNativePanelModeKeepsDataAndEveryNonDocumentBoundarySynthetic() async throws {
        let config = try nativePanelConfiguration()
        let context = try FunctionalQAContext(configuration: config)
        defer { try? context.cleanup() }
        let preferences = try config.makePreferences()
        XCTAssertTrue(preferences.isEphemeral)
        XCTAssertNil(preferences.defaults)
        let environment = context.environment(terminate: {})
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: context.directory.path)[.posixPermissions]
            as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: context.directory.path)), ["opened.txt"])
        XCTAssertEqual(try String(contentsOf: context.directory.appendingPathComponent("opened.txt"), encoding: .utf8),
                       FunctionalQAContext.openedText)
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.modelSelection.url.path))
        XCTAssertNil(environment.chooseAudioToImport(.english))
        XCTAssertThrowsError(try environment.readAudio(context.directory.appendingPathComponent("missing.wav"),
                                                        ResourcePolicy.bundled()))
        XCTAssertEqual(environment.permissionStatus(), .denied)
        let permissionGranted = await environment.requestPermission()
        XCTAssertFalse(permissionGranted)
        XCTAssertTrue(environment.inputDevices().isEmpty)
        XCTAssertNil(environment.chooseModel())
        XCTAssertNil(environment.workspaceNotifications)
        XCTAssertThrowsError(try environment.registerHotkey(.controlShiftSpace, { _ in XCTFail("No hotkey callback") }))
        XCTAssertThrowsError(try environment.restoreManagedSelection(String(repeating: "0", count: 64)))
        XCTAssertThrowsError(try environment.importManagedModel(context.modelSelection.url))
        do {
            _ = try await environment.downloadManagedModel(context.modelSelection.candidate, { _ in })
            XCTFail("Native panel QA must reject model downloads")
        } catch { XCTAssertEqual(error as? ModelDownloadFailure, .unavailableSource) }
        do {
            _ = try await context.inference.load(url: context.modelSelection.url,
                                                 candidate: context.modelSelection.candidate)
            XCTFail("Native panel QA must reject model loading")
        } catch { XCTAssertEqual(error as? DictationError, .privacyBlocked) }
        do {
            _ = try await context.inference.transcribe(SessionPCM(samples: [0.1]), language: .en,
                cancellation: try DecodeCancellation(), policy: ResourcePolicy.bundled())
            XCTFail("Native panel QA must reject inference")
        } catch { XCTAssertEqual(error as? DictationError, .privacyBlocked) }
        do {
            try await context.capture.start(session: UUID(), deviceID: nil, channel: 0,
                policy: ResourcePolicy.bundled(), authorization: CaptureStartupGate(),
                onFirstSample: { XCTFail("No captured samples") },
                onProgress: { _, _ in XCTFail("No capture progress") },
                onFailure: { _ in XCTFail("No capture failure callback") },
                onLimitReached: { _ in XCTFail("No capture limit callback") })
            XCTFail("Native panel QA must reject recording")
        } catch { XCTAssertEqual(error as? DictationError, .privacyBlocked) }

        let coordinator = AppCoordinator(policy: try ResourcePolicy.bundled(), capture: context.capture,
            inference: context.inference, environment: environment, appPreferences: preferences,
            launchConfiguration: config, modelSelection: context.modelSelection)
        XCTAssertFalse(coordinator.canStart)
        XCTAssertFalse(coordinator.canImportAudio)
        XCTAssertTrue(coordinator.canOpenTranscript)
        XCTAssertFalse(coordinator.canSaveTranscript)
        coordinator.start()
        coordinator.importAudio()
        coordinator.importModel()
        coordinator.restoreManagedModel()
        XCTAssertFalse(coordinator.operationPending)
        XCTAssertFalse(coordinator.audioFilePending)
        XCTAssertEqual(coordinator.microphone.state, .closed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.modelSelection.url.path))

        let opened = context.directory.appendingPathComponent("opened.txt")
        let saved = context.directory.appendingPathComponent("saved.txt")
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("Clavune-NativePanel-QA-outside-" + UUID().uuidString + ".txt")
        try Data("synthetic outside sentinel".utf8).write(to: outside, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: outside) }
        XCTAssertTrue(context.acceptsOpenSelection(opened))
        XCTAssertFalse(context.acceptsOpenSelection(saved))
        XCTAssertFalse(context.acceptsOpenSelection(outside))
        XCTAssertTrue(context.acceptsSaveSelection(saved))
        XCTAssertFalse(context.acceptsSaveSelection(opened))
        XCTAssertFalse(context.acceptsSaveSelection(outside))
        XCTAssertEqual(try environment.readTranscript(opened), FunctionalQAContext.openedText)
        XCTAssertThrowsError(try environment.readTranscript(outside))
        let savedText = "Synthetic panel test — Grüße 42.\n"
        try environment.writeTranscript(savedText, saved)
        XCTAssertEqual(try environment.readTranscript(saved), savedText)
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "synthetic outside sentinel")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: context.directory.path)),
                       ["opened.txt", "saved.txt"])
    }
    @MainActor func testNativePanelConvenienceFactoryKeepsOnlySyntheticOpenFileAndCleansOnQuit() async throws {
        let config = try nativePanelConfiguration()
        let terminated = expectation(description: "native-panel QA factory cleaned before termination")
        var directory: URL?
        var directoryGoneAtTermination = false
        let coordinator = try AppCoordinator(policy: ResourcePolicy.bundled(), launchConfiguration: config,
            functionalQATerminate: {
                directoryGoneAtTermination = directory.map {
                    !FileManager.default.fileExists(atPath: $0.path)
                } ?? false
                terminated.fulfill()
            })
        directory = try XCTUnwrap(coordinator.functionalQADirectory)
        XCTAssertTrue(coordinator.launchConfiguration.isNativePanelQA)
        XCTAssertFalse(coordinator.canStart)
        XCTAssertFalse(coordinator.canImportAudio)
        XCTAssertTrue(coordinator.canOpenTranscript)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: try XCTUnwrap(directory).path)),
                       ["opened.txt"])
        coordinator.start()
        coordinator.importAudio()
        coordinator.importModel()
        coordinator.restoreManagedModel()
        XCTAssertFalse(coordinator.operationPending)
        XCTAssertFalse(coordinator.audioFilePending)
        XCTAssertEqual(coordinator.microphone.state, .closed)
        coordinator.quit()
        await fulfillment(of: [terminated], timeout: 3)
        XCTAssertTrue(coordinator.terminationReady)
        XCTAssertTrue(directoryGoneAtTermination)
    }
    @MainActor func testGeneratedAudioAndTextAreBoundedAndAllLiveBoundariesDeny() async throws {
        let context = try FunctionalQAContext(configuration: configuration())
        defer { try? context.cleanup() }
        let environment = context.environment(terminate: {})
        XCTAssertEqual(environment.permissionStatus(), .denied)
        let permitted = await environment.requestPermission()
        XCTAssertFalse(permitted)
        XCTAssertTrue(environment.inputDevices().isEmpty)
        XCTAssertNil(environment.chooseModel())
        XCTAssertNil(environment.workspaceNotifications)
        XCTAssertThrowsError(try environment.registerHotkey(.controlShiftSpace, { _ in XCTFail("No global event expected") }))
        XCTAssertThrowsError(try environment.restoreManagedSelection(String(repeating: "0", count: 64)))
        let audio = try XCTUnwrap(environment.chooseAudioToImport(.english))
        let policy = try ResourcePolicy.bundled()
        let pcm = try environment.readAudio(audio, policy)
        XCTAssertEqual(pcm.sampleRate, 16_000)
        XCTAssertEqual(pcm.samples.count, 4_000)
        XCTAssertTrue(pcm.samples.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(pcm.samples.map { abs($0) }.max() ?? 0, 0.1)
        let text = try XCTUnwrap(environment.chooseTranscriptToOpen(.english))
        XCTAssertEqual(try environment.readTranscript(text), FunctionalQAContext.openedText)
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.modelSelection.url.path))
        XCTAssertEqual(context.modelSelection.candidate.sizeBytes, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: context.directory.path).count, 2)
        try context.cleanup(); try context.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.directory.path))
    }
    @MainActor func testActualGeneratedImportUsesSyntheticInferenceAndSupportsEditCopySaveOpenRepeat() async throws {
        let configuration = try configuration()
        let context = try FunctionalQAContext(configuration: configuration)
        defer { try? context.cleanup() }
        let environment = context.environment(terminate: {})
        let coordinator = AppCoordinator(policy: try ResourcePolicy.bundled(), capture: context.capture,
            inference: context.inference, environment: environment, launchConfiguration: configuration,
            modelSelection: context.modelSelection)
        XCTAssertFalse(coordinator.canStart)
        XCTAssertTrue(coordinator.canImportAudio)
        coordinator.importAudio(); await waitForOperation(coordinator)
        XCTAssertEqual(coordinator.session.phase, .review)
        XCTAssertEqual(coordinator.editedText, FunctionalQAContext.transcript)
        XCTAssertEqual(coordinator.metrics?.frames16k, 4_000)
        XCTAssertEqual(coordinator.microphone.state, .closed)
        coordinator.editedText = "Edited synthetic QA — Grüße 42, not 24."
        coordinator.copy()
        XCTAssertEqual(context.copiedText, coordinator.editedText)
        coordinator.saveTranscript(); await waitForOperation(coordinator)
        let saved = try XCTUnwrap(environment.chooseTranscriptToSave(.english))
        XCTAssertEqual(try TranscriptFileStore.read(saved), coordinator.editedText)
        let editedSnapshot = coordinator.editedText
        coordinator.discard()
        XCTAssertFalse(coordinator.hasPendingReview)
        // A fresh coordinator reopens the exact explicitly saved snapshot in this
        // retained synthetic context. This is not a real process-relaunch claim.
        let reopened = AppCoordinator(policy: try ResourcePolicy.bundled(), capture: context.capture,
            inference: context.inference, environment: environment, launchConfiguration: configuration,
            modelSelection: context.modelSelection)
        reopened.openTranscript(); await waitForOperation(reopened)
        XCTAssertEqual(reopened.editedText, editedSnapshot)
        XCTAssertFalse(reopened.canStart)
        XCTAssertEqual(reopened.microphone.state, .closed)
        reopened.discard()
        reopened.importAudio(); await waitForOperation(reopened)
        XCTAssertEqual(reopened.editedText, FunctionalQAContext.transcript)
        reopened.discard()
        await context.inference.unload()
    }
    @MainActor func testCancellationAndNoHardwareCapture() async throws {
        let context = try FunctionalQAContext(configuration: configuration())
        defer { try? context.cleanup() }
        let policy = try ResourcePolicy.bundled()
        let token = try DecodeCancellation()
        _ = try await context.inference.load(url: context.modelSelection.url, candidate: context.modelSelection.candidate)
        let inference = context.inference
        let decode = Task { try await inference.transcribe(SessionPCM(samples: [0.1, -0.1]), language: .en,
                                                           cancellation: token, policy: policy) }
        decode.cancel()
        do { _ = try await decode.value; XCTFail("Cancelled synthetic work must not produce a result") }
        catch { XCTAssertTrue(error is CancellationError) }
        do {
            try await context.capture.start(session: UUID(), deviceID: nil, channel: 0, policy: policy,
                authorization: CaptureStartupGate(), onFirstSample: { XCTFail("No capture") },
                onProgress: { _, _ in XCTFail("No capture") }, onFailure: { _ in XCTFail("No callback") },
                onLimitReached: { _ in XCTFail("No capture") })
            XCTFail("Synthetic context must refuse every capture")
        } catch { XCTAssertEqual(error as? DictationError, .privacyBlocked) }
        await context.capture.cancel(session: nil)
        await context.inference.unload()
    }
    @MainActor func testOutsideAndSymlinkBoundariesPreserveUnrelatedBytes() throws {
        let context = try FunctionalQAContext(configuration: configuration())
        defer { try? context.cleanup() }
        let environment = context.environment(terminate: {})
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("Clavune-FunctionalQA-Test-" + UUID().uuidString)
        try Data("untouched synthetic sentinel".utf8).write(to: outside, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: outside) }
        XCTAssertThrowsError(try environment.readTranscript(outside))
        XCTAssertThrowsError(try environment.writeTranscript("no", outside))
        XCTAssertThrowsError(try environment.readAudio(outside, ResourcePolicy.bundled()))
        let audio = try XCTUnwrap(environment.chooseAudioToImport(.english))
        let retained = context.directory.appendingPathComponent("retained-original.wav")
        try FileManager.default.moveItem(at: audio, to: retained)
        try FileManager.default.createSymbolicLink(at: audio, withDestinationURL: outside)
        XCTAssertThrowsError(try environment.readAudio(audio, ResourcePolicy.bundled()))
        XCTAssertThrowsError(try context.cleanup())
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "untouched synthetic sentinel")
        try FileManager.default.removeItem(at: audio)
        try FileManager.default.moveItem(at: retained, to: audio)
        try context.cleanup()
    }
    @MainActor func testReplacementAndUnknownCleanupEntriesFailClosed() throws {
        let context = try FunctionalQAContext(configuration: configuration())
        defer { try? context.cleanup() }
        let environment = context.environment(terminate: {})
        let audio = try XCTUnwrap(environment.chooseAudioToImport(.english))
        let retained = context.directory.appendingPathComponent("retained-original.wav")
        let bytes = try Data(contentsOf: audio)
        try FileManager.default.moveItem(at: audio, to: retained)
        try bytes.write(to: audio, options: .withoutOverwriting)
        XCTAssertThrowsError(try environment.readAudio(audio, ResourcePolicy.bundled()))
        XCTAssertThrowsError(try context.cleanup())
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
        try FileManager.default.removeItem(at: audio)
        try FileManager.default.moveItem(at: retained, to: audio)
        let unexpected = context.directory.appendingPathComponent("unexpected.txt")
        try Data("preserve".utf8).write(to: unexpected)
        XCTAssertThrowsError(try context.cleanup())
        XCTAssertEqual(try String(contentsOf: unexpected, encoding: .utf8), "preserve")
        try FileManager.default.removeItem(at: unexpected)
        try context.cleanup()
    }
    @MainActor func testActualConvenienceFactoryImportsCopiesSavesAndCleansBeforeTermination() async throws {
        let terminated = expectation(description: "synthetic factory terminated after cleanup")
        var directory: URL?
        var cleanupObservedAtTermination = false
        let coordinator = try AppCoordinator(policy: ResourcePolicy.bundled(),
            launchConfiguration: configuration(), functionalQATerminate: {
                cleanupObservedAtTermination = directory.map {
                    !FileManager.default.fileExists(atPath: $0.path)
                } ?? false
                terminated.fulfill()
            })
        directory = try XCTUnwrap(coordinator.functionalQADirectory)
        XCTAssertFalse(coordinator.canStart)
        coordinator.importAudio(); await waitForOperation(coordinator)
        XCTAssertEqual(coordinator.editedText, FunctionalQAContext.transcript)
        XCTAssertEqual(coordinator.microphone.state, .closed)
        coordinator.editedText = "Synthetic factory saved review. Grüße 42."
        coordinator.copy()
        XCTAssertEqual(coordinator.message,
            "QA-Kopie nur im Arbeitsspeicher. Die Systemzwischenablage bleibt unverändert.")
        coordinator.saveTranscript(); await waitForOperation(coordinator)
        let saved = try XCTUnwrap(directory).appendingPathComponent("saved.txt")
        XCTAssertEqual(try TranscriptFileStore.read(saved), coordinator.editedText)
        coordinator.discard()
        coordinator.quit()
        let outcome = await XCTWaiter.fulfillment(of: [terminated], timeout: 3)
        XCTAssertEqual(outcome, .completed)
        XCTAssertTrue(coordinator.terminationReady)
        XCTAssertTrue(cleanupObservedAtTermination, "Owned files must be removed before the termination boundary")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(directory).path))
    }
    @MainActor func testActualConvenienceFactoryPreservesUnknownEntryAndReportsCleanupFailureAtTermination() async throws {
        let terminated = expectation(description: "synthetic factory terminated preserving unknown entry")
        var sentinel: URL?
        var preservedAtTermination = false
        let coordinator = try AppCoordinator(policy: ResourcePolicy.bundled(),
            launchConfiguration: configuration(), functionalQATerminate: {
                preservedAtTermination = sentinel.flatMap { try? String(contentsOf: $0, encoding: .utf8) } == "owned test sentinel"
                terminated.fulfill()
            })
        let directory = try XCTUnwrap(coordinator.functionalQADirectory)
        sentinel = directory.appendingPathComponent("unexpected-test-only.txt")
        try Data("owned test sentinel".utf8).write(to: try XCTUnwrap(sentinel), options: .withoutOverwriting)
        // Test teardown removes only the three exact regular nodes this fixture
        // owns. It never recursively deletes unknown directory contents.
        defer {
            for name in ["unexpected-test-only.txt", "opened.txt", "synthetic.wav"] {
                let url = directory.appendingPathComponent(name)
                var info = stat()
                if lstat(url.path, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            _ = rmdir(directory.path)
        }
        coordinator.quit()
        let outcome = await XCTWaiter.fulfillment(of: [terminated], timeout: 3)
        XCTAssertEqual(outcome, .completed)
        XCTAssertTrue(coordinator.terminationReady)
        XCTAssertTrue(preservedAtTermination)
        XCTAssertEqual(coordinator.message,
            "Synthetische QA-Dateien konnten nicht sicher entfernt werden; unbekannte Dateien bleiben erhalten.")
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(sentinel), encoding: .utf8), "owned test sentinel")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
            Set(["synthetic.wav", "opened.txt", "unexpected-test-only.txt"]))
    }
}
