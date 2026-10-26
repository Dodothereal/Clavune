import Darwin
import Foundation
import XCTest
@testable import ClavuneCore

/// All bytes are synthetic, in a unique temporary directory. No user documents.
final class TranscriptFileStoreTests: XCTestCase {
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clavune-transcript-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testUTF8RoundTripAndExplicitAtomicReplacementUseExactEditedBytes() throws {
        let directory = try directory(), target = directory.appendingPathComponent("review.txt")
        for text in ["Grüß dich 👋🏽\r\nLine two\n\tfinal", "", "replacement"] {
            try TranscriptFileStore.write(text, to: target)
            XCTAssertEqual(try Data(contentsOf: target), Data(text.utf8))
            XCTAssertEqual(try TranscriptFileStore.read(target), text)
            let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["review.txt"])
        }
    }

    func testExactSizeLimitAcceptedAndLargerReadOrWritePreservesExistingBytes() throws {
        let directory = try directory(), target = directory.appendingPathComponent("review.txt")
        let atLimit = String(repeating: "a", count: TranscriptFileStore.maximumBytes)
        try TranscriptFileStore.write(atLimit, to: target)
        XCTAssertEqual(try TranscriptFileStore.read(target).utf8.count, TranscriptFileStore.maximumBytes)
        XCTAssertThrowsError(try TranscriptFileStore.write(atLimit + "a", to: target))
        XCTAssertEqual(try Data(contentsOf: target), Data(atLimit.utf8))
        let oversized = directory.appendingPathComponent("oversized.txt")
        try Data((atLimit + "a").utf8).write(to: oversized)
        XCTAssertThrowsError(try TranscriptFileStore.read(oversized))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(),
                       ["oversized.txt", "review.txt"])
    }

    func testMalformedUTF8RejectedWithoutLossyConversionOrInputMutation() throws {
        let directory = try directory(), target = directory.appendingPathComponent("invalid.txt")
        let invalid = Data([0x61, 0xC3, 0x28])
        try invalid.write(to: target)
        XCTAssertThrowsError(try TranscriptFileStore.read(target)) { error in
            guard case TranscriptFileStore.Failure.invalidUTF8 = error else {
                return XCTFail("Expected strict UTF-8 rejection")
            }
        }
        XCTAssertEqual(try Data(contentsOf: target), invalid)
    }

    func testTruncatedMultibyteUTF8TailRejectedWithoutChangingSavedBytes() throws {
        let directory = try directory()
        let cases: [(String, Data)] = [
            ("truncated-two-byte.txt", Data([0x63, 0x61, 0x66, 0xC3])),
            ("truncated-three-byte.txt", Data([0xE2, 0x82])),
            ("truncated-four-byte.txt", Data([0xF0, 0x9F, 0x8C]))
        ]
        for (name, bytes) in cases {
            let target = directory.appendingPathComponent(name)
            try bytes.write(to: target)
            XCTAssertThrowsError(try TranscriptFileStore.read(target), name) { error in
                guard case TranscriptFileStore.Failure.invalidUTF8 = error else {
                    return XCTFail("Expected strict UTF-8 rejection for an incomplete scalar")
                }
            }
            XCTAssertEqual(try Data(contentsOf: target), bytes, "A rejected read must not rewrite the saved file")
        }
    }

    func testNonFileURLsMissingFilesDirectoriesAndSymlinksAreRejected() throws {
        let directory = try directory(), target = directory.appendingPathComponent("review.txt")
        try Data("keep target".utf8).write(to: target)
        let link = directory.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        for url in [try XCTUnwrap(URL(string: "https://example.invalid/transcript.txt")), directory, link] {
            XCTAssertThrowsError(try TranscriptFileStore.read(url))
            XCTAssertThrowsError(try TranscriptFileStore.write("must not replace", to: url))
        }
        XCTAssertThrowsError(try TranscriptFileStore.read(directory.appendingPathComponent("missing.txt")))
        XCTAssertEqual(try Data(contentsOf: target), Data("keep target".utf8))
    }

    func testFIFOReadAndWriteAreRejectedWithoutWaitingForAProducer() throws {
        let directory = try directory(), fifo = directory.appendingPathComponent("pipe.txt")
        XCTAssertEqual(mkfifo(fifo.path, mode_t(0o600)), 0)
        XCTAssertThrowsError(try TranscriptFileStore.read(fifo))
        XCTAssertThrowsError(try TranscriptFileStore.write("not a pipe writer", to: fifo))
    }

    func testUnavailableDestinationDoesNotCreateDirectoriesOrChangeExistingFile() throws {
        let directory = try directory(), target = directory.appendingPathComponent("review.txt")
        try Data("keep".utf8).write(to: target)
        let missing = directory.appendingPathComponent("missing/new.txt")
        XCTAssertThrowsError(try TranscriptFileStore.write("new", to: missing))
        XCTAssertEqual(try Data(contentsOf: target), Data("keep".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["review.txt"])
    }

    func testCancelledReadAndSaveDoNotTouchFiles() async throws {
        let directory = try directory(), target = directory.appendingPathComponent("review.txt")
        try Data("keep".utf8).write(to: target)
        // The worker cancels itself before entering either production boundary.
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            XCTAssertThrowsError(try TranscriptFileStore.read(target))
            XCTAssertThrowsError(try TranscriptFileStore.write("must not save", to: target))
        }
        try await operation.value
        XCTAssertEqual(try Data(contentsOf: target), Data("keep".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["review.txt"])
    }

    func testOpenedTextHasNewReviewIdentityAndCannotReplaceBusySession() throws {
        var session = SessionMachine()
        XCTAssertTrue(session.openTranscript(""))
        let opened = session.id
        XCTAssertEqual(session.phase, .review)
        XCTAssertTrue(session.openTranscript("another file"))
        XCTAssertNotEqual(session.id, opened)
        XCTAssertEqual(session.rawTranscript, "another file")
        let recording = try session.begin()
        XCTAssertFalse(session.openTranscript("must not replace"))
        XCTAssertEqual(session.id, recording)
        XCTAssertEqual(session.phase, .preparing)
    }
}
