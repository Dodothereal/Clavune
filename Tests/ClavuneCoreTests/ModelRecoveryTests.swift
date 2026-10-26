import Foundation
import XCTest
@testable import ClavuneCore

final class ModelRecoveryTests: XCTestCase {
    private var root: URL!
    private var directory: URL!
    private var source: URL!
    private var destination: URL!
    private let originalBytes = Data("abc".utf8)
    // SHA-256 of the public synthetic fixture "abc"; not a model weight file.
    private let candidate = ModelCandidate(
        fileName: "synthetic-fixture.bin", sizeBytes: 3,
        sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        role: "test-fixture", license: "MIT", qualityGate: "unmeasured")

    override func setUpWithError() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        root = project.appendingPathComponent(".build/model-recovery-" + UUID().uuidString)
        directory = root.appendingPathComponent("managed")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        source = root.appendingPathComponent("original-fixture.bin")
        destination = directory.appendingPathComponent(candidate.sha256 + ".bin")
        try originalBytes.write(to: source)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func inode(_ url: URL) throws -> UInt64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attrs[.systemFileNumber] as? NSNumber).uint64Value
    }
    private func assertNoImportTemporary() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(names.contains { $0.hasPrefix(".import-") })
    }

    func testCorruptDestinationIsReplacedWithNewInodeAndOneRecoverableBackup() throws {
        let corrupt = Data("bad".utf8)
        try corrupt.write(to: destination)
        let previousInode = try inode(destination)
        let openOldFile = try FileHandle(forReadingFrom: destination)
        defer { try? openOldFile.close() }
        let unrelated = directory.appendingPathComponent("keep.txt")
        try Data("unrelated".utf8).write(to: unrelated)

        let installed = try ModelStore.importModel(source, into: directory, candidates: [candidate])
        let backup = ModelStore.recoveryBackupURL(in: directory)
        XCTAssertEqual(installed.url, destination)
        XCTAssertFalse(installed.reusedVerifiedFile)
        XCTAssertEqual(try Data(contentsOf: destination), originalBytes)
        XCTAssertEqual(try Data(contentsOf: source), originalBytes)
        XCTAssertEqual(try Data(contentsOf: backup), corrupt)
        XCTAssertEqual(try inode(backup), previousInode)
        XCTAssertNotEqual(try inode(destination), previousInode)
        try openOldFile.seek(toOffset: 0)
        XCTAssertEqual(try openOldFile.readToEnd(), corrupt)
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("unrelated".utf8))
        try assertNoImportTemporary()
    }
    func testExistingValidModelIsReusedWithoutBackupOrSourceChange() throws {
        try originalBytes.write(to: destination)
        let existingInode = try inode(destination)
        let installed = try ModelStore.importModel(source, into: directory, candidates: [candidate])
        XCTAssertTrue(installed.reusedVerifiedFile)
        XCTAssertEqual(try inode(destination), existingInode)
        XCTAssertEqual(try Data(contentsOf: source), originalBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ModelStore.recoveryBackupURL(in: directory).path))
        try assertNoImportTemporary()
    }
    func testExistingRecoveryBackupIsNeverOverwritten() throws {
        let corrupt = Data("bad".utf8), priorBackup = Data("previous recovery".utf8)
        try corrupt.write(to: destination)
        let backup = ModelStore.recoveryBackupURL(in: directory)
        try priorBackup.write(to: backup)
        XCTAssertThrowsError(try ModelStore.importModel(source, into: directory, candidates: [candidate])) { error in
            XCTAssertEqual(error as? ModelStore.RecoveryError, .backupAlreadyExists)
        }
        XCTAssertEqual(try Data(contentsOf: destination), corrupt)
        XCTAssertEqual(try Data(contentsOf: backup), priorBackup)
        XCTAssertEqual(try Data(contentsOf: source), originalBytes)
        try assertNoImportTemporary()
    }
    func testUnverifiedIncomingFileCannotMoveAnExistingModel() throws {
        let corrupt = Data("bad".utf8)
        try corrupt.write(to: destination)
        try Data("xyz".utf8).write(to: source)
        XCTAssertThrowsError(try ModelStore.importModel(source, into: directory, candidates: [candidate])) { error in
            XCTAssertEqual(error as? DictationError, .modelMismatch)
        }
        XCTAssertEqual(try Data(contentsOf: destination), corrupt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ModelStore.recoveryBackupURL(in: directory).path))
        try assertNoImportTemporary()
    }
    func testOversizedExistingFileIsRefusedWithoutBackupGrowth() throws {
        let oversized = Data("over budget".utf8)
        try oversized.write(to: destination)
        XCTAssertThrowsError(try ModelStore.importModel(source, into: directory, candidates: [candidate])) { error in
            XCTAssertEqual(error as? ModelStore.RecoveryError, .existingFileExceedsBudget)
        }
        XCTAssertEqual(try Data(contentsOf: destination), oversized)
        XCTAssertEqual(try Data(contentsOf: source), originalBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ModelStore.recoveryBackupURL(in: directory).path))
        try assertNoImportTemporary()
    }
    func testSymlinkDestinationDoesNotModifyItsTarget() throws {
        let unrelated = root.appendingPathComponent("unrelated.bin")
        let bytes = Data("bad".utf8)
        try bytes.write(to: unrelated)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: unrelated)
        XCTAssertThrowsError(try ModelStore.importModel(source, into: directory, candidates: [candidate])) { error in
            XCTAssertEqual(error as? ModelStore.RecoveryError, .unsafeExistingEntry)
        }
        XCTAssertEqual(try Data(contentsOf: unrelated), bytes)
        XCTAssertEqual(try destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ModelStore.recoveryBackupURL(in: directory).path))
        try assertNoImportTemporary()
    }
    func testSavedSelectionRestoresOnlyVerifiedManagedFileWithoutMutation() throws {
        try originalBytes.write(to: destination)
        let before = try inode(destination)
        let installed = try ModelStore.restoreSelection(candidate.sha256, in: directory, candidates: [candidate])
        XCTAssertEqual(installed.url, destination)
        XCTAssertEqual(installed.candidate.sha256, candidate.sha256)
        XCTAssertFalse(installed.reusedVerifiedFile)
        XCTAssertEqual(try inode(destination), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [candidate.sha256 + ".bin"])
    }
    func testSavedSelectionRejectsCorruptFileAndPreservesBackup() throws {
        let corrupt = Data("bad".utf8)
        try corrupt.write(to: destination)
        let backup = ModelStore.recoveryBackupURL(in: directory)
        try originalBytes.write(to: backup)
        XCTAssertThrowsError(try ModelStore.restoreSelection(candidate.sha256, in: directory, candidates: [candidate]))
        XCTAssertEqual(try Data(contentsOf: destination), corrupt)
        XCTAssertEqual(try Data(contentsOf: backup), originalBytes)
    }
    func testSavedSelectionDoesNotUseMissingDestinationBackupOrUnknownPath() throws {
        let backup = ModelStore.recoveryBackupURL(in: directory)
        try originalBytes.write(to: backup)
        XCTAssertThrowsError(try ModelStore.restoreSelection(candidate.sha256, in: directory, candidates: [candidate]))
        XCTAssertThrowsError(try ModelStore.restoreSelection("../original-fixture", in: directory, candidates: [candidate]))
        XCTAssertEqual(try Data(contentsOf: backup), originalBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
    func testSavedSelectionRejectsSymbolicLinkEvenWithVerifiedTarget() throws {
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: source)
        XCTAssertThrowsError(try ModelStore.restoreSelection(candidate.sha256, in: directory, candidates: [candidate]))
        XCTAssertEqual(try Data(contentsOf: source), originalBytes)
    }

}
