import AppKit
import Darwin
import Dispatch
import Foundation
import XCTest
@testable import ClavuneApp
@testable import ClavuneCore

/// A filtered child XCTest worker saves and opens one synthetic transcript in
/// separate processes. This exercises coordinator persistence across a process
/// boundary; it does not claim to launch or quit the SwiftUI application.
final class CrossProcessTranscriptPersistenceTests: UIFixtureAssertions {
    private static let expectedText = "Synthetic Clavune review — Grüße\nSecond line, unchanged."
    private static let seedText = "Synthetic transcript opened before editing."
    private static let phaseKey = "CLAVUNE_PROCESS_PERSISTENCE_PHASE"
    private static let rootKey = "CLAVUNE_PROCESS_PERSISTENCE_ROOT"

    private enum WorkerLaunchError: Error {
        case timedOut
        case childMayStillBeRunning
    }

    @MainActor func testCrossProcessSaveQuitOpen() async throws {
        let environment = ProcessInfo.processInfo.environment
        if let phase = environment[Self.phaseKey] {
            try await runWorker(phase: phase, rootPath: try XCTUnwrap(environment[Self.rootKey]))
            return
        }
        try await runParentScenario()
    }

    @MainActor private func runParentScenario() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("Clavune-CrossProcessPersistence-" + UUID().uuidString,
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        var preserveRootForUnconfirmedChild = false
        defer {
            if !preserveRootForUnconfirmedChild {
                try? FileManager.default.removeItem(at: root)
            }
        }

        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let seed = root.appendingPathComponent("seed.txt")
        guard FileManager.default.createFile(atPath: seed.path, contents: Data(Self.seedText.utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw NSError(domain: "CrossProcessTranscriptPersistenceTests", code: 8,
                          userInfo: [NSLocalizedDescriptionKey: "Unable to create synthetic seed transcript"])
        }

        let save: WorkerResult
        do {
            save = try launchWorker(phase: "save", root: root,
                                    temporaryDirectory: root.deletingLastPathComponent(), home: home)
        } catch WorkerLaunchError.childMayStillBeRunning {
            preserveRootForUnconfirmedChild = true
            throw WorkerLaunchError.childMayStillBeRunning
        }
        guard save.exitCode == 0 else {
            XCTFail("Save worker exited \(save.exitCode): \(safeDiagnostic(save.stdout + "\n" + save.stderr))")
            return
        }
        let transcript = root.appendingPathComponent("review.txt")
        XCTAssertEqual(try Data(contentsOf: transcript), Data(Self.expectedText.utf8),
                       "Saved file is exact UTF-8 text with no session metadata or wrapper")
        XCTAssertEqual(try TranscriptFileStore.read(transcript), Self.expectedText)
        XCTAssertEqual(try Data(contentsOf: seed), Data(Self.seedText.utf8),
                       "Saving a different transcript must leave the synthetic seed unchanged")
        let permissions = try FileManager.default.attributesOfItem(atPath: transcript.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)

        let saveMetadata = try readWorkerMetadata(root.appendingPathComponent("save.meta"))
        XCTAssertNotEqual(saveMetadata.pid, getpid(), "The save phase must run in a child process")

        let open: WorkerResult
        do {
            open = try launchWorker(phase: "open", root: root,
                                    temporaryDirectory: root.deletingLastPathComponent(), home: home)
        } catch WorkerLaunchError.childMayStillBeRunning {
            preserveRootForUnconfirmedChild = true
            throw WorkerLaunchError.childMayStillBeRunning
        }
        guard open.exitCode == 0 else {
            XCTFail("Open worker exited \(open.exitCode): \(safeDiagnostic(open.stdout + "\n" + open.stderr))")
            return
        }
        let openMetadata = try readWorkerMetadata(root.appendingPathComponent("open.meta"))
        XCTAssertNotEqual(openMetadata.pid, saveMetadata.pid, "Save and Open must run in different processes")
        XCTAssertNotEqual(openMetadata.sessionID, saveMetadata.sessionID,
                          "An opened transcript gets a fresh review identity")
        XCTAssertEqual(try Data(contentsOf: transcript), Data(Self.expectedText.utf8),
                       "Reading in the new process must not mutate the saved bytes")
    }

    private struct WorkerMetadata {
        let pid: Int32
        let sessionID: UUID
    }

    private func readWorkerMetadata(_ url: URL) throws -> WorkerMetadata {
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        guard lines.count == 2, let pid = Int32(lines[0]), let sessionID = UUID(uuidString: String(lines[1])) else {
            throw NSError(domain: "CrossProcessTranscriptPersistenceTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid synthetic worker metadata"])
        }
        return WorkerMetadata(pid: pid, sessionID: sessionID)
    }

    private struct WorkerResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private func launchWorker(phase: String, root: URL, temporaryDirectory: URL, home: URL) throws -> WorkerResult {
        let executable = URL(fileURLWithPath: "/usr/bin/xcrun")
        let bundle = Bundle(for: Self.self).bundleURL
        guard FileManager.default.isExecutableFile(atPath: executable.path),
              bundle.pathExtension == "xctest", FileManager.default.fileExists(atPath: bundle.path) else {
            throw NSError(domain: "CrossProcessTranscriptPersistenceTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Filtered XCTest runner is unavailable"])
        }

        let output = root.appendingPathComponent("\(phase).stdout")
        let errors = root.appendingPathComponent("\(phase).stderr")
        guard FileManager.default.createFile(atPath: output.path, contents: Data(),
                                             attributes: [.posixPermissions: 0o600]),
              FileManager.default.createFile(atPath: errors.path, contents: Data(),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw NSError(domain: "CrossProcessTranscriptPersistenceTests", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Unable to create private child logs"])
        }
        let stdoutHandle = try FileHandle(forWritingTo: output)
        let stderrHandle = try FileHandle(forWritingTo: errors)
        defer { try? stdoutHandle.close(); try? stderrHandle.close() }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["xctest", "-XCTest",
                             "CrossProcessTranscriptPersistenceTests/testCrossProcessSaveQuitOpen", bundle.path]
        // Child workers get only the toolchain basics and their unique synthetic
        // fixture paths. Do not copy the parent's environment or any secrets.
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": home.path,
            "TMPDIR": temporaryDirectory.path,
            "LANG": "C.UTF-8",
            Self.phaseKey: phase,
            Self.rootKey: root.path
        ]
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        guard exited.wait(timeout: .now() + 30) == .success else {
            if process.isRunning { process.terminate() }
            if exited.wait(timeout: .now() + 5) == .timedOut {
                // Escalate only against the exact child started above, then
                // reap it before returning so a timed-out fixture cannot leave
                // an XCTest worker behind.
                let childPID = process.processIdentifier
                guard kill(childPID, SIGKILL) == 0 || errno == ESRCH else {
                    throw WorkerLaunchError.childMayStillBeRunning
                }
                process.waitUntilExit()
            }
            throw WorkerLaunchError.timedOut
        }
        process.waitUntilExit()
        try stdoutHandle.synchronize()
        try stderrHandle.synchronize()
        let stdout = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
        let stderr = (try? String(contentsOf: errors, encoding: .utf8)) ?? ""
        return WorkerResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    private func safeDiagnostic(_ text: String) -> String {
        var lines: [String] = [], hidingEnvironment = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.contains("Displaying process arguments and environment") {
                hidingEnvironment = true
                continue
            }
            if hidingEnvironment {
                if line.trimmingCharacters(in: .whitespaces) == "}" { hidingEnvironment = false }
                continue
            }
            if line.hasPrefix("Arguments:") || line.hasPrefix("Environment:") { continue }
            lines.append(line)
        }
        return lines.suffix(24).joined(separator: "\n")
    }

    @MainActor private func runWorker(phase: String, rootPath: String) async throws {
        let root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        try validateFixtureRoot(root, phase: phase)
        let transcript = root.appendingPathComponent("review.txt")
        switch phase {
        case "save":
            let seed = root.appendingPathComponent("seed.txt")
            let fixture = try CoordinatorFixture(modelSelectionEnabled: false, configureEnvironment: { environment in
                environment.chooseTranscriptToOpen = { _ in seed }
                environment.readTranscript = { try TranscriptFileStore.read($0) }
                environment.chooseTranscriptToSave = { _ in transcript }
                environment.writeTranscript = { try TranscriptFileStore.write($0, to: $1) }
                environment.confirmUnsavedReviewQuit = { _ in .save }
            })
            fixture.coordinator.openTranscript()
            await waitForOperation(fixture)
            XCTAssertEqual(fixture.coordinator.session.rawTranscript, Self.seedText)
            XCTAssertEqual(fixture.coordinator.session.phase, .review)
            XCTAssertEqual(fixture.coordinator.microphone.state, .closed)
            XCTAssertNil(fixture.coordinator.metrics)
            XCTAssertFalse(fixture.coordinator.canStart)
            XCTAssertEqual(fixture.inference.counts.value.loads, 0)
            XCTAssertEqual(fixture.inference.counts.value.decodes, 0)
            XCTAssertEqual(fixture.resources.counts.value.opened, 0)
            XCTAssertTrue(fixture.clipboard.calls.isEmpty)
            fixture.coordinator.editedText = Self.expectedText
            let savedSession = try XCTUnwrap(fixture.coordinator.session.id)
            fixture.terminated = expectation(description: "synthetic save drained before child exit")
            fixture.coordinator.quit()
            await fulfillment(of: [try XCTUnwrap(fixture.terminated)], timeout: 3)
            XCTAssertEqual(fixture.terminationCalls, 1)
            XCTAssertTrue(fixture.coordinator.terminationReady)
            XCTAssertEqual(try TranscriptFileStore.read(transcript), Self.expectedText)
            XCTAssertEqual(fixture.inference.counts.value.loads, 0)
            XCTAssertEqual(fixture.inference.counts.value.decodes, 0)
            try writeWorkerMetadata(pid: getpid(), sessionID: savedSession, to: root.appendingPathComponent("save.meta"))

        case "open":
            let fixture = try CoordinatorFixture(modelSelectionEnabled: false, configureEnvironment: { environment in
                environment.chooseTranscriptToOpen = { _ in transcript }
                environment.readTranscript = { try TranscriptFileStore.read($0) }
            })
            fixture.coordinator.openTranscript()
            await waitForOperation(fixture)
            XCTAssertEqual(fixture.coordinator.session.phase, .review)
            XCTAssertEqual(fixture.coordinator.session.rawTranscript, Self.expectedText)
            XCTAssertEqual(fixture.coordinator.editedText, Self.expectedText)
            XCTAssertFalse(fixture.coordinator.hasUnsavedReview)
            XCTAssertNil(fixture.coordinator.metrics, "Transcript files carry no runtime/session metrics")
            XCTAssertEqual(fixture.coordinator.microphone.state, .closed)
            XCTAssertFalse(fixture.coordinator.canStart, "Opening text does not implicitly select or load a model")
            XCTAssertEqual(fixture.inference.counts.value.loads, 0)
            XCTAssertEqual(fixture.inference.counts.value.decodes, 0)
            XCTAssertEqual(fixture.resources.counts.value.opened, 0)
            XCTAssertTrue(fixture.clipboard.calls.isEmpty)
            let openedSession = try XCTUnwrap(fixture.coordinator.session.id)
            fixture.terminated = expectation(description: "clean opened review quit")
            fixture.coordinator.quit()
            await fulfillment(of: [try XCTUnwrap(fixture.terminated)], timeout: 3)
            XCTAssertEqual(fixture.terminationCalls, 1)
            try writeWorkerMetadata(pid: getpid(), sessionID: openedSession, to: root.appendingPathComponent("open.meta"))

        default:
            XCTFail("Unsupported synthetic persistence phase")
        }
    }

    private func validateFixtureRoot(_ root: URL, phase: String) throws {
        let prefix = "Clavune-CrossProcessPersistence-"
        let name = root.lastPathComponent
        let expectedParent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let actualParent = root.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        var info = stat()
        guard ["save", "open"].contains(phase), name.hasPrefix(prefix),
              UUID(uuidString: String(name.dropFirst(prefix.count))) != nil,
              actualParent == expectedParent,
              root.resolvingSymlinksInPath() == root,
              lstat(root.path, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              (info.st_mode & 0o777) == 0o700, info.st_uid == geteuid() else {
            throw NSError(domain: "CrossProcessTranscriptPersistenceTests", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "Unsafe synthetic persistence fixture root"])
        }
        let target = root.appendingPathComponent("review.txt")
        var targetInfo = stat()
        if phase == "save" {
            guard lstat(target.path, &targetInfo) != 0, errno == ENOENT else {
                throw NSError(domain: "CrossProcessTranscriptPersistenceTests", code: 6,
                              userInfo: [NSLocalizedDescriptionKey: "Save fixture target must be new"])
            }
            let seed = root.appendingPathComponent("seed.txt")
            guard lstat(seed.path, &targetInfo) == 0,
                  (targetInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                  (targetInfo.st_mode & 0o777) == 0o600, targetInfo.st_uid == geteuid() else {
                throw NSError(domain: "CrossProcessTranscriptPersistenceTests", code: 9,
                              userInfo: [NSLocalizedDescriptionKey: "Save seed is not a private synthetic file"])
            }
        } else {
            guard lstat(target.path, &targetInfo) == 0,
                  (targetInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                  (targetInfo.st_mode & 0o777) == 0o600, targetInfo.st_uid == geteuid() else {
                throw NSError(domain: "CrossProcessTranscriptPersistenceTests", code: 7,
                              userInfo: [NSLocalizedDescriptionKey: "Open fixture target is not a private regular file"])
            }
        }
    }

    private func writeWorkerMetadata(pid: Int32, sessionID: UUID, to url: URL) throws {
        let data = Data("\(pid)\n\(sessionID.uuidString)\n".utf8)
        guard FileManager.default.createFile(atPath: url.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw NSError(domain: "CrossProcessTranscriptPersistenceTests", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Unable to record synthetic worker metadata"])
        }
    }
}
