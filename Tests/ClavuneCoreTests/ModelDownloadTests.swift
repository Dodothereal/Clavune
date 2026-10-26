import CryptoKit
import Combine
import Foundation
import XCTest
@testable import ClavuneApp
@testable import ClavuneCore

final class ModelDownloadTests: UIFixtureAssertions {
    private let payload = Data("bounded synthetic model bytes".utf8)
    private var root: URL!
    private var candidate: ModelCandidate!
    private var preserveRootForUndrainedTask = false

    override func setUpWithError() throws {
        preserveRootForUndrainedTask = false
        root = FileManager.default.temporaryDirectory.appendingPathComponent("clavune-download-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let revision = String(repeating: "a", count: 40)
        candidate = ModelCandidate(fileName: "synthetic.bin", sizeBytes: Int64(payload.count), sha256: hash,
            role: "test-fixture", license: "MIT", qualityGate: "unmeasured",
            sourceURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/\(revision)/synthetic.bin"),
            sourceRevision: revision, downloadEnabled: true)
        ModelDownloadProtocolFixture.reset()
    }

    override func tearDownWithError() throws {
        // A failed liveness check is invalid evidence. Do not delete a root
        // that an incompletely drained task could still own.
        guard !preserveRootForUndrainedTask else { return }
        try? FileManager.default.removeItem(at: root)
    }

    func testFailureGateWaitsForReleaseAndDeliversOnlyOnce() {
        let gate = ModelDownloadFailureGate(), calls = FixtureValue(0)
        gate.arm { calls.update { $0 += 1 } }
        XCTAssertEqual(calls.value, 0)
        gate.release(); gate.release()
        gate.arm { calls.update { $0 += 100 } }
        XCTAssertEqual(calls.value, 1)
    }

    func testFailureGateHandlesEarlyReleaseAndPendingCancellation() {
        let released = ModelDownloadFailureGate(), earlyCalls = FixtureValue(0)
        released.release()
        released.arm { earlyCalls.update { $0 += 1 } }
        XCTAssertEqual(earlyCalls.value, 1)

        let cancelled = ModelDownloadFailureGate(), cancelledCalls = FixtureValue(0)
        cancelled.arm { cancelledCalls.update { $0 += 1 } }
        cancelled.cancel(); cancelled.release()
        XCTAssertEqual(cancelledCalls.value, 0)

        let cancelledBeforeArm = ModelDownloadFailureGate()
        cancelledBeforeArm.cancel(); cancelledBeforeArm.release()
        cancelledBeforeArm.arm { cancelledCalls.update { $0 += 1 } }
        XCTAssertEqual(cancelledCalls.value, 0)
    }

    func testPreRequestOpenFailureReleasesTransferAndAllowsExplicitRetry() async throws {
        let part = root.appendingPathComponent(".download-\(candidate.sha256).part")
        let record = part.appendingPathExtension("json")
        var transfer: ModelDownloadTransfer? = try ModelDownloadTransfer(candidate: candidate,
            source: try XCTUnwrap(candidate.sourceURL), directory: root,
            configuration: testSessionConfiguration(), progress: { _ in })
        weak var observedTransfer = transfer
        let recordBefore = try Data(contentsOf: record)
        // Deterministic synthetic open failure; no permission assumptions or sleeps.
        try FileManager.default.removeItem(at: part)
        do {
            _ = try await transfer!.perform()
            XCTFail("Missing partial must fail before request admission")
        } catch {
            let failure = error as NSError
            XCTAssertEqual(failure.domain, NSCocoaErrorDomain)
            XCTAssertEqual(failure.code, NSFileNoSuchFileError)
        }
        transfer = nil
        XCTAssertNil(observedTransfer, "No idle URLSession may retain the failed transfer")
        XCTAssertTrue(ModelDownloadProtocolFixture.requests.isEmpty)
        XCTAssertEqual(try Data(contentsOf: record), recordBefore)

        // Explicitly repair only this synthetic missing partial, then retry normally.
        try Data().write(to: part)
        ModelDownloadProtocolFixture.enqueue(.init(status: 200,
            headers: ["Content-Length": "\(payload.count)"], chunks: [payload]))
        let installed = try await ModelDownloadService.download(candidate, into: root,
            sessionConfiguration: testSessionConfiguration())
        XCTAssertEqual(try Data(contentsOf: installed.url), payload)
        XCTAssertEqual(ModelDownloadProtocolFixture.requests.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: part.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.path))
    }

    func testPreRequestRecordFailurePreservesUnknownEntryWithoutNetwork() throws {
        let part = root.appendingPathComponent(".download-\(candidate.sha256).part")
        let record = part.appendingPathExtension("json")
        // An existing directory makes the atomic record write fail deterministically.
        try FileManager.default.createDirectory(at: record, withIntermediateDirectories: false)
        XCTAssertThrowsError(try ModelDownloadTransfer(candidate: candidate,
            source: try XCTUnwrap(candidate.sourceURL), directory: root,
            configuration: testSessionConfiguration(), progress: { _ in }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: part.path))
        XCTAssertTrue(try record.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
        XCTAssertTrue(ModelDownloadProtocolFixture.requests.isEmpty)
    }

    func testInterruptedTransferResumesWithRangeAndInstallsOnlyVerifiedBytes() async throws {
        // URLSession may coalesce very small custom-protocol body callbacks. Use
        // a bounded prefix above the production progress threshold so this test
        // proves bytes reached the delegate before simulating the interruption.
        let interruptedPayload = Data(repeating: 0x41, count: 2_100_000)
        let hash = SHA256.hash(data: interruptedPayload).map { String(format: "%02x", $0) }.joined()
        let resumeFileName = "synthetic-resume.bin"
        let resumeURL = try XCTUnwrap(candidate.sourceURL).deletingLastPathComponent()
            .appendingPathComponent(resumeFileName)
        let interruptedCandidate = ModelCandidate(fileName: "synthetic-resume.bin",
            sizeBytes: Int64(interruptedPayload.count), sha256: hash, role: "test-fixture",
            license: "MIT", qualityGate: "unmeasured", sourceURL: resumeURL,
            sourceRevision: candidate.sourceRevision, downloadEnabled: true)
        let split = 1_100_000
        ModelDownloadProtocolFixture.enqueue(.init(status: 200,
            headers: ["Content-Length": "\(interruptedPayload.count)", "ETag": "\"fixed-v1\""],
            chunks: [interruptedPayload.prefix(split)], errorAfterChunks: URLError(.networkConnectionLost)))
        let observedProgress = FixtureValue<Int64>(0)
        do {
            _ = try await ModelDownloadService.download(interruptedCandidate, into: root,
                sessionConfiguration: testSessionConfiguration(), progress: { value in
                    observedProgress.update { $0 = value }
                })
            XCTFail("The synthetic first connection must stop early")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .networkConnectionLost)
        } catch {
            XCTFail("Unexpected failure before the synthetic transport interruption: \(error)")
        }

        let part = root.appendingPathComponent(".download-\(interruptedCandidate.sha256).part")
        XCTAssertEqual(observedProgress.value, Int64(split), "The URLSession delegate must receive the partial body")
        XCTAssertEqual(try Data(contentsOf: part), interruptedPayload.prefix(split))
        ModelDownloadProtocolFixture.enqueue(.init(status: 206,
            headers: ["Content-Length": "\(interruptedPayload.count - split)",
                      "Content-Range": "bytes \(split)-\(interruptedPayload.count - 1)/\(interruptedPayload.count)",
                      "ETag": "\"fixed-v1\""],
            chunks: [interruptedPayload.suffix(from: split)]))
        let installed = try await ModelDownloadService.download(interruptedCandidate, into: root,
            sessionConfiguration: testSessionConfiguration())

        XCTAssertEqual(try Data(contentsOf: installed.url), interruptedPayload)
        XCTAssertEqual(installed.candidate.sha256, interruptedCandidate.sha256)
        let installedAttributes = try FileManager.default.attributesOfItem(atPath: installed.url.path)
        XCTAssertEqual((installedAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o400)
        XCTAssertEqual(ModelDownloadProtocolFixture.requests.last?.value(forHTTPHeaderField: "Range"),
                       "bytes=\(split)-")
        XCTAssertEqual(ModelDownloadProtocolFixture.requests.last?.value(forHTTPHeaderField: "If-Range"),
                       "\"fixed-v1\"")
        XCTAssertFalse(FileManager.default.fileExists(atPath: part.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: part.appendingPathExtension("json").path))
    }

    func testUserCancellationKeepsReceivedBytesAndCanResumeExplicitly() async throws {
        let body = Data(repeating: 0x43, count: 2_100_000)
        let hash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let resumableCandidate = ModelCandidate(fileName: candidate.fileName,
            sizeBytes: Int64(body.count), sha256: hash, role: "test-fixture", license: "MIT",
            qualityGate: "unmeasured", sourceURL: candidate.sourceURL,
            sourceRevision: candidate.sourceRevision, downloadEnabled: true)
        let split = 1_100_000
        ModelDownloadProtocolFixture.enqueue(.init(status: 200,
            headers: ["Content-Length": "\(body.count)", "ETag": "\"cancel-v1\""],
            chunks: [body.prefix(split)], hangAfterChunks: true))
        let received = expectation(description: "Partial body reached the streaming writer")
        let task = Task {
            try await ModelDownloadService.download(resumableCandidate, into: root,
                sessionConfiguration: testSessionConfiguration(), progress: { bytes in
                    if bytes == Int64(split) { received.fulfill() }
                })
        }
        await fulfillment(of: [received], timeout: 2)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("User cancellation must not report a completed install")
        } catch is CancellationError {
            // Expected: the partial stays local for an explicit later resume.
        }

        let part = root.appendingPathComponent(".download-\(hash).part")
        let record = part.appendingPathExtension("json")
        XCTAssertEqual(try Data(contentsOf: part), body.prefix(split))
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.path))
        let partialAttributes = try FileManager.default.attributesOfItem(atPath: part.path)
        let recordAttributes = try FileManager.default.attributesOfItem(atPath: record.path)
        XCTAssertEqual((partialAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((recordAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(hash + ".bin").path))

        ModelDownloadProtocolFixture.enqueue(.init(status: 206,
            headers: ["Content-Length": "\(body.count - split)",
                      "Content-Range": "bytes \(split)-\(body.count - 1)/\(body.count)",
                      "ETag": "\"cancel-v1\""],
            chunks: [body.suffix(from: split)]))
        let installed = try await ModelDownloadService.download(resumableCandidate, into: root,
            sessionConfiguration: testSessionConfiguration())
        XCTAssertEqual(try Data(contentsOf: installed.url), body)
        XCTAssertFalse(FileManager.default.fileExists(atPath: part.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.path))
        XCTAssertEqual(ModelDownloadProtocolFixture.requests.last?.value(forHTTPHeaderField: "Range"),
                       "bytes=\(split)-")
        XCTAssertEqual(ModelDownloadProtocolFixture.requests.last?.value(forHTTPHeaderField: "If-Range"),
                       "\"cancel-v1\"")
    }

    func testCancellationDuringFinalVerificationKeepsCompletePartialUnactivated() async throws {
        let body = Data("complete synthetic payload held before atomic activation".utf8)
        let hash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let revision = try XCTUnwrap(candidate.sourceRevision)
        let source = try XCTUnwrap(URL(string:
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/\(revision)/verify-cancel.bin"))
        let value = ModelCandidate(fileName: "verify-cancel.bin", sizeBytes: Int64(body.count), sha256: hash,
            role: "test-fixture", license: "MIT", qualityGate: "unmeasured", sourceURL: source,
            sourceRevision: revision, downloadEnabled: true)
        ModelDownloadProtocolFixture.enqueue(.init(status: 200,
            headers: ["Content-Length": "\(body.count)", "ETag": "\"verify-cancel-v1\""], chunks: [body]))

        let reachedActivation = expectation(description: "Hash verification reached the activation boundary")
        let releaseActivation = DispatchSemaphore(value: 0)
        let task = Task {
            try await ModelDownloadService.download(value, into: root,
                sessionConfiguration: testSessionConfiguration(), progress: { _ in },
                beforeActivation: {
                    reachedActivation.fulfill()
                    releaseActivation.wait()
                })
        }
        await fulfillment(of: [reachedActivation], timeout: 2)
        task.cancel()
        releaseActivation.signal()
        do {
            _ = try await task.value
            XCTFail("Cancellation before atomic activation must not report an install")
        } catch is CancellationError {
            // The complete, verified bytes remain resumable until explicit retry.
        }

        let part = root.appendingPathComponent(".download-\(hash).part")
        let record = part.appendingPathExtension("json")
        XCTAssertEqual(try Data(contentsOf: part), body)
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(hash + ".bin").path))
    }

    func testCancellationBeforeVerifierTaskAttachmentCancelsNewDetachedTask() async throws {
        let body = Data("synthetic cancellation before child registration".utf8)
        let hash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let revision = try XCTUnwrap(candidate.sourceRevision)
        let source = try XCTUnwrap(URL(string:
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/\(revision)/registration-cancel.bin"))
        let value = ModelCandidate(fileName: "registration-cancel.bin", sizeBytes: Int64(body.count), sha256: hash,
            role: "test-fixture", license: "MIT", qualityGate: "unmeasured", sourceURL: source,
            sourceRevision: revision, downloadEnabled: true)
        ModelDownloadProtocolFixture.enqueue(.init(status: 200,
            headers: ["Content-Length": "\(body.count)", "ETag": "\"registration-cancel-v1\""], chunks: [body]))

        let beforeAttachment = expectation(description: "Parent entered the verified-install cancellation scope")
        let allowAttachment = DispatchSemaphore(value: 0)
        let task = Task {
            try await ModelDownloadService.download(value, into: root,
                sessionConfiguration: testSessionConfiguration(), progress: { _ in },
                beforeInstallTask: {
                    beforeAttachment.fulfill()
                    allowAttachment.wait()
                }, beforeActivation: nil)
        }
        await fulfillment(of: [beforeAttachment], timeout: 2)
        task.cancel()
        allowAttachment.signal()
        do {
            _ = try await task.value
            XCTFail("Cancellation before child attachment must prevent verification and install")
        } catch is CancellationError {
            // The handoff must cancel a child attached after onCancel ran.
        }

        let part = root.appendingPathComponent(".download-\(hash).part")
        XCTAssertEqual(try Data(contentsOf: part), body)
        XCTAssertTrue(FileManager.default.fileExists(atPath: part.appendingPathExtension("json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(hash + ".bin").path))
    }

    func testResumeWithoutStrongETagRestartsFromZero() async throws {
        for (index, etag) in [String?.none, "W/\"weak-v1\""].enumerated() {
            let body = Data(repeating: UInt8(0x50 + index), count: 65_536)
            let hash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
            let revision = try XCTUnwrap(candidate.sourceRevision)
            let name = "no-validator-\(index).bin"
            let source = try XCTUnwrap(URL(string:
                "https://huggingface.co/ggerganov/whisper.cpp/resolve/\(revision)/\(name)"))
            let value = ModelCandidate(fileName: name, sizeBytes: Int64(body.count), sha256: hash,
                role: "test-fixture", license: "MIT", qualityGate: "unmeasured", sourceURL: source,
                sourceRevision: revision, downloadEnabled: true)
            var headers = ["Content-Length": "\(body.count)"]
            if let etag { headers["ETag"] = etag }
            ModelDownloadProtocolFixture.enqueue(.init(status: 200, headers: headers,
                chunks: [body.prefix(32_768)], errorAfterChunks: URLError(.networkConnectionLost)))
            do {
                _ = try await ModelDownloadService.download(value, into: root,
                    sessionConfiguration: testSessionConfiguration())
                XCTFail("The synthetic first transfer must be interrupted")
            } catch let error as URLError {
                XCTAssertEqual(error.code, .networkConnectionLost)
            }

            ModelDownloadProtocolFixture.enqueue(.init(status: 200,
                headers: ["Content-Length": "\(body.count)", "ETag": "\"fresh-v\(index)\""], chunks: [body]))
            let installed = try await ModelDownloadService.download(value, into: root,
                sessionConfiguration: testSessionConfiguration())
            XCTAssertEqual(try Data(contentsOf: installed.url), body)
            XCTAssertNil(ModelDownloadProtocolFixture.requests.last?.value(forHTTPHeaderField: "Range"))
            XCTAssertNil(ModelDownloadProtocolFixture.requests.last?.value(forHTTPHeaderField: "If-Range"))
        }
    }

    func testFreshUnvalidatedResponseClearsStaleZeroByteETagBeforeResume() async throws {
        let body = Data(repeating: 0x6b, count: 2_100_000)
        let hash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let revision = try XCTUnwrap(candidate.sourceRevision)
        let name = "stale-validator.bin"
        let source = try XCTUnwrap(URL(string:
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/\(revision)/\(name)"))
        let value = ModelCandidate(fileName: name, sizeBytes: Int64(body.count), sha256: hash,
            role: "test-fixture", license: "MIT", qualityGate: "unmeasured",
            sourceURL: source, sourceRevision: revision, downloadEnabled: true)
        let part = root.appendingPathComponent(".download-\(hash).part")
        let record = part.appendingPathExtension("json")

        // Seed a valid zero-byte record directly. URLProtocol may skip its
        // response callback when an empty-body connection fails immediately.
        try Data().write(to: part)
        let saved = ["sha256": hash, "fileName": name,
                     "sourceURL": source.absoluteString, "eTag": "\"stale-v1\""]
        try JSONSerialization.data(withJSONObject: saved).write(to: record)
        let oldRecord = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: record))
            as? [String: Any])
        XCTAssertEqual(oldRecord["eTag"] as? String, "\"stale-v1\"")

        // This new full response has no tag. Its bytes must not inherit the old
        // tag merely because a zero-byte record was present on entry.
        // Exactly one production progress quantum: even if URLSession splits
        // callbacks, this acknowledgement proves the entire prefix was written.
        let split = 1024 * 1024
        let failureGate = ModelDownloadFailureGate()
        let received = expectation(description: "No-ETag prefix reached the streaming writer")
        let completed = expectation(description: "Gated no-ETag transfer drained")
        ModelDownloadProtocolFixture.enqueue(.init(status: 200,
            headers: ["Content-Length": "\(body.count)"], chunks: [body.prefix(split)],
            errorAfterChunks: URLError(.networkConnectionLost), failureGate: failureGate))
        let transfer = Task {
            defer { completed.fulfill() }
            return try await ModelDownloadService.download(value, into: root,
                sessionConfiguration: testSessionConfiguration(), progress: { bytes in
                    if bytes == Int64(split) { received.fulfill() }
                })
        }
        defer { failureGate.cancel(); transfer.cancel() }
        let observed = await XCTWaiter.fulfillment(of: [received], timeout: 2)
        if observed == .completed {
            failureGate.release()
        } else {
            transfer.cancel(); failureGate.cancel()
        }
        let drained = await XCTWaiter.fulfillment(of: [completed], timeout: 2)
        guard drained == .completed else {
            preserveRootForUndrainedTask = true
            XCTFail("Undrained synthetic transfer is invalid evidence; its generated root is preserved")
            return
        }
        guard observed == .completed else {
            _ = await transfer.result
            XCTFail("The production writer did not acknowledge the prefix before the bounded deadline")
            return
        }
        do {
            _ = try await transfer.value
            XCTFail("The synthetic connection must stop with partial bytes")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .networkConnectionLost)
        }
        XCTAssertEqual(try Data(contentsOf: part), body.prefix(split))
        let newRecord = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: record))
            as? [String: Any])
        XCTAssertNil(newRecord["eTag"], "The no-ETag body is not a validated resumable entity")

        ModelDownloadProtocolFixture.enqueue(.init(status: 200,
            headers: ["Content-Length": "\(body.count)", "ETag": "\"fresh-v2\""], chunks: [body]))
        let installed = try await ModelDownloadService.download(value, into: root,
            sessionConfiguration: testSessionConfiguration())
        XCTAssertEqual(try Data(contentsOf: installed.url), body)
        XCTAssertEqual(ModelDownloadProtocolFixture.requests.count, 2)
        XCTAssertNil(ModelDownloadProtocolFixture.requests.last?.value(forHTTPHeaderField: "Range"))
        XCTAssertNil(ModelDownloadProtocolFixture.requests.last?.value(forHTTPHeaderField: "If-Range"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: part.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.path))
    }

    func testCompleteUnvalidatedPartRetriesRecoveryWithoutAnotherDownload() async throws {
        for (index, etag) in [String?.none, "W/\"weak-v1\""].enumerated() {
            let directory = root.appendingPathComponent("complete-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let destination = directory.appendingPathComponent(candidate.sha256 + ".bin")
            let oldBytes = Data("bad existing model".utf8)
            try oldBytes.write(to: destination)
            let backup = ModelStore.recoveryBackupURL(in: directory)
            let earlierBackup = Data("earlier recovery".utf8)
            try earlierBackup.write(to: backup)

            var headers = ["Content-Length": "\(payload.count)"]
            if let etag { headers["ETag"] = etag }
            ModelDownloadProtocolFixture.enqueue(.init(status: 200, headers: headers, chunks: [payload]))
            do {
                _ = try await ModelDownloadService.download(candidate, into: directory,
                    sessionConfiguration: testSessionConfiguration())
                XCTFail("An earlier recovery backup must not be overwritten")
            } catch let error as ModelStore.RecoveryError {
                XCTAssertEqual(error, .backupAlreadyExists)
            }

            let part = directory.appendingPathComponent(".download-\(candidate.sha256).part")
            let record = part.appendingPathExtension("json")
            XCTAssertEqual(try Data(contentsOf: part), payload)
            XCTAssertTrue(FileManager.default.fileExists(atPath: record.path))
            let partAttributes = try FileManager.default.attributesOfItem(atPath: part.path)
            XCTAssertEqual((partAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o400)
            XCTAssertEqual(try Data(contentsOf: destination), oldBytes)
            XCTAssertEqual(try Data(contentsOf: backup), earlierBackup)
            XCTAssertEqual(ModelDownloadProtocolFixture.requests.count, index + 1)

            do {
                _ = try await ModelDownloadService.download(candidate, into: directory,
                    sessionConfiguration: testSessionConfiguration())
                XCTFail("Retry must still honor the occupied recovery slot")
            } catch let error as ModelStore.RecoveryError {
                XCTAssertEqual(error, .backupAlreadyExists)
            }
            XCTAssertEqual(ModelDownloadProtocolFixture.requests.count, index + 1)
            XCTAssertEqual(try Data(contentsOf: part), payload)
            XCTAssertEqual(try Data(contentsOf: destination), oldBytes)
            XCTAssertEqual(try Data(contentsOf: backup), earlierBackup)

            try FileManager.default.removeItem(at: backup)
            // No second URLProtocol plan exists. The complete part must be rehashed
            // locally, not opened for append or silently trusted by byte count.
            let installed = try await ModelDownloadService.download(candidate, into: directory,
                sessionConfiguration: testSessionConfiguration())
            XCTAssertEqual(try Data(contentsOf: installed.url), payload)
            XCTAssertEqual(ModelDownloadProtocolFixture.requests.count, index + 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: part.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: record.path))
            XCTAssertEqual(try Data(contentsOf: backup), oldBytes)
        }
    }

    func testCompleteUnvalidatedPartIsRehashedAndRejectedWhenChanged() async throws {
        let destination = root.appendingPathComponent(candidate.sha256 + ".bin")
        let oldBytes = Data("bad existing model".utf8)
        try oldBytes.write(to: destination)
        let backup = ModelStore.recoveryBackupURL(in: root)
        let earlierBackup = Data("earlier recovery".utf8)
        try earlierBackup.write(to: backup)
        ModelDownloadProtocolFixture.enqueue(.init(status: 200,
            headers: ["Content-Length": "\(payload.count)"], chunks: [payload]))
        do {
            _ = try await ModelDownloadService.download(candidate, into: root,
                sessionConfiguration: testSessionConfiguration())
            XCTFail("An earlier recovery backup must block activation")
        } catch let error as ModelStore.RecoveryError {
            XCTAssertEqual(error, .backupAlreadyExists)
        }

        let part = root.appendingPathComponent(".download-\(candidate.sha256).part")
        let record = part.appendingPathExtension("json")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: part.path)
        let handle = try FileHandle(forWritingTo: part)
        try handle.write(contentsOf: Data(repeating: 0x58, count: payload.count))
        try handle.close()
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: part.path)
        try FileManager.default.removeItem(at: backup)

        do {
            _ = try await ModelDownloadService.download(candidate, into: root,
                sessionConfiguration: testSessionConfiguration())
            XCTFail("A complete byte count is not proof of the model hash")
        } catch let error as DictationError {
            XCTAssertEqual(error, .modelMismatch)
        }
        XCTAssertEqual(ModelDownloadProtocolFixture.requests.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: part.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.path))
        XCTAssertEqual(try Data(contentsOf: destination), oldBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    func testRedirectPolicyAllowsOnlyExplicitHTTPSDeliveryHosts() throws {
        for host in ["huggingface.co", "cdn-lfs.huggingface.co", "cas-bridge.xethub.hf.co", "transfer.xethub.hf.co"] {
            let url = try XCTUnwrap(URL(string: "https://\(host)/model.bin"))
            XCTAssertTrue(ModelDownloadService.permitsRedirect(to: url),
                          "Expected the explicitly allowed HTTPS delivery host \(host)")
        }
        for url in [
            "http://huggingface.co/model.bin",
            "https://huggingface.co.attacker.example/model.bin",
            "https://attacker.example/model.bin",
            "https://user@huggingface.co/model.bin",
            "https://huggingface.co:8443/model.bin"
        ] {
            let deniedURL = try XCTUnwrap(URL(string: url))
            XCTAssertFalse(ModelDownloadService.permitsRedirect(to: deniedURL),
                           "Unexpectedly permitted redirect \(url)")
        }
    }

    func testResumeRejectsChangedETagAndPreservesUntrustedPartialWithoutActivation() async throws {
        let body = Data(repeating: 0x42, count: 2_100_000)
        let hash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let resumableCandidate = ModelCandidate(fileName: candidate.fileName,
            sizeBytes: Int64(body.count), sha256: hash, role: "test-fixture", license: "MIT",
            qualityGate: "unmeasured", sourceURL: candidate.sourceURL,
            sourceRevision: candidate.sourceRevision, downloadEnabled: true)
        let split = 1_100_000
        ModelDownloadProtocolFixture.enqueue(.init(status: 200,
            headers: ["Content-Length": "\(body.count)", "ETag": "\"version-1\""],
            chunks: [body.prefix(split)], errorAfterChunks: URLError(.networkConnectionLost)))
        do {
            _ = try await ModelDownloadService.download(resumableCandidate, into: root,
                sessionConfiguration: testSessionConfiguration())
            XCTFail("The first connection must stop before completion")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .networkConnectionLost)
        }
        let part = root.appendingPathComponent(".download-\(hash).part")
        XCTAssertEqual(try Data(contentsOf: part), body.prefix(split))

        ModelDownloadProtocolFixture.enqueue(.init(status: 206,
            headers: ["Content-Length": "\(body.count - split)",
                      "Content-Range": "bytes \(split)-\(body.count - 1)/\(body.count)",
                      "ETag": "\"version-2\""],
            chunks: [body.suffix(from: split)]))
        do {
            _ = try await ModelDownloadService.download(resumableCandidate, into: root,
                sessionConfiguration: testSessionConfiguration())
            XCTFail("A changed entity tag must not be appended to a prior partial")
        } catch let error as ModelDownloadFailure {
            XCTAssertEqual(error, .changedSource)
        }
        XCTAssertEqual(try Data(contentsOf: part), body.prefix(split))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(hash + ".bin").path))
        XCTAssertEqual(ModelDownloadProtocolFixture.requests.last?.value(forHTTPHeaderField: "Range"),
                       "bytes=\(split)-")
        XCTAssertEqual(ModelDownloadProtocolFixture.requests.last?.value(forHTTPHeaderField: "If-Range"),
                       "\"version-1\"")

        ModelDownloadProtocolFixture.enqueue(.init(status: 206,
            headers: ["Content-Length": "\(body.count - split)",
                      "Content-Range": "bytes \(split)-\(body.count - 2)/\(body.count)",
                      "ETag": "\"version-1\""],
            chunks: [body.suffix(from: split)]))
        do {
            _ = try await ModelDownloadService.download(resumableCandidate, into: root,
                sessionConfiguration: testSessionConfiguration())
            XCTFail("A partial Content-Range must describe the requested remainder exactly")
        } catch let error as ModelDownloadFailure {
            XCTAssertEqual(error, .rejectedResponse)
        }
        XCTAssertEqual(try Data(contentsOf: part), body.prefix(split))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(hash + ".bin").path))
    }

    func testWrongHashIsNeverInstalledAndItsCompletedPartialIsRemoved() async throws {
        ModelDownloadProtocolFixture.enqueue(.init(status: 200,
            headers: ["Content-Length": "\(payload.count)"],
            chunks: [Data(repeating: 0x58, count: payload.count)]))
        do {
            _ = try await ModelDownloadService.download(candidate, into: root,
                sessionConfiguration: testSessionConfiguration())
            XCTFail("Wrong model bytes must not be activated")
        } catch let error as DictationError {
            XCTAssertEqual(error, .modelMismatch)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(candidate.sha256 + ".bin").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".download-\(candidate.sha256).part").path))
    }

    func testOversizedResponseChunkIsRejectedBeforeWritingPastCandidateBound() async throws {
        ModelDownloadProtocolFixture.enqueue(.init(status: 200,
            headers: ["Content-Length": "\(payload.count)"],
            chunks: [Data(repeating: 0x59, count: payload.count + 1)]))
        do {
            _ = try await ModelDownloadService.download(candidate, into: root,
                sessionConfiguration: testSessionConfiguration())
            XCTFail("The downloader must not persist bytes beyond the manifest size")
        } catch let error as ModelDownloadFailure {
            XCTAssertEqual(error, .transferTooLarge)
        }
        let part = root.appendingPathComponent(".download-\(candidate.sha256).part")
        let attributes = try FileManager.default.attributesOfItem(atPath: part.path)
        XCTAssertEqual((attributes[.size] as? NSNumber)?.intValue, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(candidate.sha256 + ".bin").path))
    }

    func testUnpinnedOrDisabledSourcesFailBeforeNetwork() async throws {
        let disabled = ModelCandidate(fileName: candidate.fileName, sizeBytes: candidate.sizeBytes,
            sha256: candidate.sha256, role: candidate.role, license: candidate.license,
            qualityGate: candidate.qualityGate, sourceURL: candidate.sourceURL,
            sourceRevision: candidate.sourceRevision, downloadEnabled: false)
        do {
            _ = try await ModelDownloadService.download(disabled, into: root,
                sessionConfiguration: testSessionConfiguration())
            XCTFail("Disabled downloads must fail closed")
        } catch let error as ModelDownloadFailure {
            XCTAssertEqual(error, .unavailableSource)
        }
        XCTAssertTrue(ModelDownloadProtocolFixture.requests.isEmpty)

        let unpinned = ModelCandidate(fileName: candidate.fileName, sizeBytes: candidate.sizeBytes,
            sha256: candidate.sha256, role: candidate.role, license: candidate.license,
            qualityGate: candidate.qualityGate,
            sourceURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/synthetic.bin"),
            sourceRevision: "main", downloadEnabled: true)
        do {
            _ = try await ModelDownloadService.download(unpinned, into: root,
                sessionConfiguration: testSessionConfiguration())
            XCTFail("Mutable branch references must not be downloaded")
        } catch let error as ModelDownloadFailure {
            XCTAssertEqual(error, .invalidSource)
        }
        XCTAssertTrue(ModelDownloadProtocolFixture.requests.isEmpty)
    }

    func testLegacyCandidateDataDefaultsToNonDownloadable() throws {
        let legacy = Data("""
            {"fileName":"legacy.bin","sizeBytes":12,"sha256":"abc","role":"legacy",
             "license":"MIT","qualityGate":"unmeasured"}
            """.utf8)
        let decoded = try JSONDecoder().decode(ModelCandidate.self, from: legacy)
        XCTAssertNil(decoded.sourceURL)
        XCTAssertNil(decoded.sourceRevision)
        XCTAssertFalse(decoded.downloadEnabled)
    }

    func testPublishedCandidatesUsePinnedHTTPSRevisionAndExactPublishedHashes() throws {
        let expected: [String: (String, String)] = [
            "ggml-large-v3-turbo-q5_0.bin": ("98aa99a0a9db05ae2342309f5096248665f7cba3", "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"),
            "ggml-large-v3-turbo-q8_0.bin": ("0b364b566045a405be7225ee1e415a073e04da77", "317eb69c11673c9de1e1f0d459b253999804ec71ac4c23c17ecf5fbe24e259a1"),
            "ggml-large-v3-turbo.bin": ("98aa99a0a9db05ae2342309f5096248665f7cba3", "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"),
            "ggml-large-v3.bin": ("362722b3fdcd2300b58a8286933ead1c48619667", "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2")
        ]
        let catalogue = try ModelStore.catalogue()
        XCTAssertFalse(catalogue.releaseApproved)
        XCTAssertNil(catalogue.defaultModel)
        let models = catalogue.models
        XCTAssertEqual(models.count, expected.count)
        for model in models {
            guard let (revision, hash) = expected[model.fileName] else {
                XCTFail("Unexpected downloadable model \(model.fileName)"); continue
            }
            XCTAssertTrue(model.downloadEnabled)
            XCTAssertEqual(model.sourceRevision, revision)
            XCTAssertEqual(model.sha256, hash)
            XCTAssertEqual(model.sourceURL?.absoluteString,
                "https://huggingface.co/ggerganov/whisper.cpp/resolve/\(revision)/\(model.fileName)")
        }
    }

    @MainActor func testCoordinatorCancelDuringDownloadKeepsPreviouslySelectedModel() async throws {
        let suite = "Clavune.ModelDownloadCancelTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let originalCandidate = try XCTUnwrap(ModelStore.candidates().first)
        defaults.set(originalCandidate.sha256, forKey: "selectedModelSHA256")
        let downloadStarted = expectation(description: "Coordinator admitted the explicit download")
        let fixture = try CoordinatorFixture(preferences: defaults, configureEnvironment: { environment in
            environment.downloadManagedModel = { candidate, _ in
                downloadStarted.fulfill()
                try await Task.sleep(for: .seconds(1))
                return ModelStore.Installed(url: URL(fileURLWithPath: "/synthetic-cancelled-download"),
                                            candidate: candidate)
            }
        })
        let original = try XCTUnwrap(fixture.coordinator.model)
        let requested = try XCTUnwrap(ModelStore.candidates().last)
        XCTAssertEqual(original.sha256, originalCandidate.sha256)
        XCTAssertNotEqual(original.sha256, requested.sha256)

        fixture.coordinator.downloadModel(requested)
        await fulfillment(of: [downloadStarted], timeout: 2)
        let operationFinished = expectation(description: "Cancelled download released its admission")
        fixture.observeOperationFinished(operationFinished)
        fixture.coordinator.cancel()
        await fulfillment(of: [operationFinished], timeout: 2)

        XCTAssertEqual(fixture.coordinator.model?.sha256, original.sha256)
        XCTAssertEqual(defaults.string(forKey: "selectedModelSHA256"), original.sha256)
        XCTAssertEqual(fixture.coordinator.modelStatus,
                       "Download abgebrochen; bisheriges Modell ausgewählt")
        XCTAssertEqual(fixture.resources.counts.value.opened, 0)
        XCTAssertEqual(fixture.permissionCalls, 0)
        XCTAssertEqual(fixture.inference.counts.value.loads, 0)
    }

    @MainActor func testCoordinatorCancelDuringDownloadPreservesPendingReview() async throws {
        let suite = "Clavune.ModelDownloadReviewCancelTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let originalCandidate = try XCTUnwrap(ModelStore.candidates().first)
        defaults.set(originalCandidate.sha256, forKey: "selectedModelSHA256")
        let downloadStarted = expectation(description: "Coordinator admitted the explicit download")
        let cancellationSeen = FixtureValue(false)
        let fixture = try CoordinatorFixture(preferences: defaults, configureEnvironment: { environment in
            environment.downloadManagedModel = { candidate, _ in
                downloadStarted.fulfill()
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    cancellationSeen.value = true
                    throw error
                }
                return ModelStore.Installed(url: URL(fileURLWithPath: "/synthetic-review-cancelled-download"),
                                            candidate: candidate)
            }
        })
        fixture.inference.transcript = "synthetic original result"
        await startRecording(fixture)
        await stopToReview(fixture)
        fixture.coordinator.editedText = "synthetic edited review"
        let reviewID = fixture.coordinator.session.id
        let rawText = fixture.coordinator.session.rawTranscript
        let original = try XCTUnwrap(fixture.coordinator.model)
        let requested = try XCTUnwrap(ModelStore.candidates().last)
        XCTAssertEqual(original.sha256, originalCandidate.sha256)
        XCTAssertNotEqual(original.sha256, requested.sha256)

        fixture.coordinator.downloadModel(requested)
        await fulfillment(of: [downloadStarted], timeout: 2)
        let operationFinished = expectation(description: "Cancelled download released its admission")
        fixture.observeOperationFinished(operationFinished)
        fixture.coordinator.cancel()
        await fulfillment(of: [operationFinished], timeout: 2)

        XCTAssertTrue(cancellationSeen.value)
        XCTAssertEqual(fixture.coordinator.session.phase, .review)
        XCTAssertEqual(fixture.coordinator.session.id, reviewID)
        XCTAssertEqual(fixture.coordinator.session.rawTranscript, rawText)
        XCTAssertEqual(fixture.coordinator.editedText, "synthetic edited review")
        XCTAssertEqual(fixture.coordinator.model?.sha256, original.sha256)
        XCTAssertEqual(defaults.string(forKey: "selectedModelSHA256"), original.sha256)
        XCTAssertEqual(fixture.coordinator.microphone.state, .closed)
        XCTAssertTrue(fixture.clipboard.calls.isEmpty)
    }

    @MainActor func testCoordinatorActivatesOnlyCompletedCatalogueDownloadAndShowsProgress() async throws {
        let suite = "Clavune.ModelDownloadTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let models = try ModelStore.candidates()
        let selected = try XCTUnwrap(models.last)
        let downloads = FixtureValue<[String]>([])
        let progressSeen = expectation(description: "Coordinator exposes downloaded byte progress")
        let fixture = try CoordinatorFixture(preferences: defaults, configureEnvironment: { environment in
            environment.downloadManagedModel = { candidate, report in
                downloads.update { $0.append(candidate.sha256) }
                report(123)
                try await Task.sleep(for: .milliseconds(30))
                return ModelStore.Installed(url: URL(fileURLWithPath: "/synthetic-download-never-opened"),
                                            candidate: candidate)
            }
        })
        fixture.coordinator.$modelStatus
            .filter { $0 == "\(selected.fileName): 123 / \(selected.sizeBytes) Bytes" }
            .prefix(1).sink { _ in progressSeen.fulfill() }.store(in: &fixture.observations)

        fixture.coordinator.downloadModel(selected)
        let done = expectation(description: "Verified model activation settles")
        fixture.observeOperationFinished(done)
        await fulfillment(of: [progressSeen, done], timeout: 2)

        XCTAssertEqual(downloads.value, [selected.sha256])
        XCTAssertEqual(fixture.coordinator.model?.sha256, selected.sha256)
        XCTAssertEqual(defaults.string(forKey: "selectedModelSHA256"), selected.sha256)
        XCTAssertEqual(fixture.coordinator.modelStatus,
                       selected.fileName + " — Hash geprüft, Qualität noch ungemessen")
        XCTAssertEqual(fixture.resources.counts.value.opened, 0)
        XCTAssertEqual(fixture.permissionCalls, 0)
        XCTAssertEqual(fixture.inference.counts.value.loads, 0)

        let unpinned = ModelCandidate(fileName: selected.fileName, sizeBytes: selected.sizeBytes,
            sha256: selected.sha256, role: selected.role, license: selected.license,
            qualityGate: selected.qualityGate,
            sourceURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(selected.fileName)"),
            sourceRevision: "main", downloadEnabled: true)
        fixture.coordinator.downloadModel(unpinned)
        XCTAssertEqual(downloads.value, [selected.sha256], "Only a byte-for-byte catalogue source may be requested")

        let alteredSize = ModelCandidate(fileName: selected.fileName, sizeBytes: selected.sizeBytes - 1,
            sha256: selected.sha256, role: selected.role, license: selected.license,
            qualityGate: selected.qualityGate, sourceURL: selected.sourceURL,
            sourceRevision: selected.sourceRevision, downloadEnabled: true)
        fixture.coordinator.downloadModel(alteredSize)
        XCTAssertEqual(downloads.value, [selected.sha256], "The UI action must use the complete manifest candidate")
    }

    private func testSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelDownloadURLProtocol.self]
        return configuration
    }
}
