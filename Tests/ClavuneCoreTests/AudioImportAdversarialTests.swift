// Synthetic bundled fixtures only. No private files, microphone, or real model.
import CryptoKit
import Foundation
import XCTest
@testable import ClavuneCore

final class NativeAudioAdversarialTests: XCTestCase {
    private struct Fixture: Decodable {
        let name: String
        let `extension`: String
        let base64: String
        let sha256: String
    }
    private struct Manifest: Decodable { let fixtures: [Fixture] }

    private func source(_ name: String) throws -> (Data, String) {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "synthetic-audio-formats", withExtension: "json",
            subdirectory: "Fixtures"))
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
        let fixture = try XCTUnwrap(manifest.fixtures.first { $0.name == name })
        let bytes = try XCTUnwrap(Data(base64Encoded: fixture.base64))
        XCTAssertEqual(sha256(bytes), fixture.sha256)
        return (bytes, fixture.extension)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func topLevelBoxes(_ bytes: Data) -> [(name: String, start: Int, end: Int)] {
        var boxes: [(name: String, start: Int, end: Int)] = []
        var cursor = 0
        while cursor + 8 <= bytes.count {
            let length = (Int(bytes[cursor]) << 24) | (Int(bytes[cursor + 1]) << 16)
                | (Int(bytes[cursor + 2]) << 8) | Int(bytes[cursor + 3])
            guard length >= 8, cursor + length <= bytes.count else { return [] }
            let name = String(bytes: bytes[(cursor + 4)..<(cursor + 8)], encoding: .ascii) ?? ""
            boxes.append((name, cursor, cursor + length))
            cursor += length
        }
        return cursor == bytes.count ? boxes : []
    }

    private func withTemporaryFile<T>(_ name: String, _ bytes: Data,
                                      _ body: (URL) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clavune-audio-adversarial-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(name)
        try bytes.write(to: url)
        let result = try body(url)
        XCTAssertEqual(try Data(contentsOf: url), bytes, "Selected audio bytes must be unchanged on return")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [name],
                       "No staging file may remain in this fixture directory")
        return result
    }

    func testIntactFaststartM4AAndALACRemainDecodable() throws {
        let policy = try ResourcePolicy.bundled()
        for name in ["m4a", "alac"] {
            let (bytes, ext) = try source(name)
            try withTemporaryFile("baseline-\(name).\(ext)", bytes) { url in
                let result = try AudioFileImporter.read(url, policy: policy)
                XCTAssertTrue((3500...5000).contains(result.samples.count),
                              "Clean tone must not be a severely partial decode")
                XCTAssertTrue(result.samples.allSatisfy(\.isFinite))
                let rms = sqrt(result.samples.reduce(0.0) { $0 + Double($1) * Double($1) }
                               / Double(result.samples.count))
                XCTAssertTrue((0.03...0.15).contains(rms), "Clean tone energy must be plausible")
            }
        }
    }

    func testContainerDeclaredM4AAndALACDurationCannotSilentlyReturnPartialAudio() throws {
        let policy = try ResourcePolicy.bundled()
        for name in ["m4a", "alac"] {
            let (full, ext) = try source(name)
            // Pin test meaning even if the bundled generated fixture is regenerated.
            let originalHash = name == "m4a"
                ? "1fd121980c915c481de2bbd5f3e1e3a204f4aae0ac86dead4967cee899cdb2c2"
                : "3ac8b8dcce649282668af6c4e1ce67e81a9ceaf2a0c8e4689648dc79a3b24b0f"
            let expectedMdatStart = name == "m4a" ? 850 : 738
            let cutHashes = name == "m4a"
                ? ["81e809f15b89bea9fa398aaa50bf1346f63369731f712427bb7f20e9dd27ce9e",
                   "fd11d64062d70f3ab71dbb8a873ab4b2f8e0112a1d99eacaebb0ed3027fdd7b3"]
                : ["f66db513a521a105d236d69aa17ef4f66ab6284ca3d35cfd190ea8402bddaa47",
                   "74d87f3ed8c1b530bc7d70a743ed98703af84c398d2c4fac9767d8e528394cfd"]
            guard sha256(full) == originalHash else {
                XCTFail("Bundled M4A/ALAC fixture changed; re-derive mutation before interpreting result")
                return
            }
            let boxes = topLevelBoxes(full)
            let moov = try XCTUnwrap(boxes.first { $0.name == "moov" })
            let mdat = try XCTUnwrap(boxes.first { $0.name == "mdat" })
            guard moov.end <= mdat.start, mdat.start == expectedMdatStart,
                  mdat.end == full.count else {
                XCTFail("Pinned fixture no longer has expected faststart moov/mdat layout")
                return
            }
            // Both preserve ftyp/moov and declared duration; only mdat is shortened.
            // Exact offsets and hashes are also in adversarial_fixtures/manifest.json.
            for (index, stop) in [full.count / 2, full.count - 64].enumerated() {
                guard stop > mdat.start + 8, stop < mdat.end else {
                    XCTFail("Mutation no longer cuts only inside mdat"); return
                }
                let partial = Data(full.prefix(stop))
                guard sha256(partial) == cutHashes[index] else {
                    XCTFail("Mutation hash changed; do not interpret decoder outcome"); return
                }
                try withTemporaryFile("truncated-\(name)-\(stop).\(ext)", partial) { url in
                    do {
                        let decoded = try AudioFileImporter.read(url, policy: policy)
                        XCTFail("Incomplete \(name) at byte \(stop) returned \(decoded.samples.count) frames")
                    } catch let failure as AudioFileImporter.Failure {
                        // Synthetic shape and error case only; never log file paths or audio bytes.
                        print("Synthetic truncated \(name) at byte \(stop) rejected: \(failure)")
                    } catch {
                        XCTFail("Unexpected rejection type \(type(of: error)) for \(name) at byte \(stop)")
                    }
                }
            }
        }
    }

}
