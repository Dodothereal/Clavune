import AVFoundation
import CryptoKit
import Foundation
import XCTest
@testable import ClavuneApp
@testable import ClavuneCore

/// Actual native file decoder, tiny reproducible generated tones. No app decoder dependency.
final class CompressedAudioImporterTests: UIFixtureAssertions {
    private struct Fixture: Decodable {
        let name: String
        let `extension`: String
        let bytes: Int
        let sha256: String
        let base64: String
    }
    private struct Manifest: Decodable { let fixtures: [Fixture] }
    private func fixtures() throws -> [Fixture] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "synthetic-audio-formats",
                                                  withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url)).fixtures
    }
    private func bytes(_ fixture: Fixture) throws -> Data {
        let data = try XCTUnwrap(Data(base64Encoded: fixture.base64))
        XCTAssertEqual(data.count, fixture.bytes)
        XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), fixture.sha256)
        return data
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clavune-codecs-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }
    func testM4AAACAndMP3ActuallyDecodeGeneratedMonoAndStereoTonesWithoutWAVStaging() throws {
        let directory = try directory(), policy = try ResourcePolicy.bundled()
        let all = try fixtures()
        XCTAssertEqual(Set(all.map(\.name)), Set(["m4a", "aac", "mp3", "alac"]))
        for fixture in all {
            let data = try bytes(fixture), url = directory.appendingPathComponent(fixture.name + "." + fixture.extension)
            try data.write(to: url)
            let result = try AudioFileImporter.read(url, policy: policy)
            // Encoder padding varies by container; preserve native priming/remainder handling.
            // 0.25 s source: output must retain the tone, not just accept a file header.
            XCTAssertTrue((3500...5000).contains(result.samples.count), fixture.extension)
            XCTAssertTrue(result.samples.allSatisfy(\.isFinite), fixture.extension)
            let rms = sqrt(result.samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(result.samples.count))
            XCTAssertTrue((0.03...0.15).contains(rms), "Missing/incorrect decoded tone: " + fixture.extension)
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(),
                       ["aac.aac", "alac.m4a", "m4a.m4a", "mp3.mp3"])
    }
    @MainActor func testGeneratedMonoM4AReachesReviewThroughActualImporterAndCoordinator() async throws {
        let directory = try directory()
        let tone = try XCTUnwrap(fixtures().first { $0.name == "m4a" })
        let data = try bytes(tone), url = directory.appendingPathComponent("mono-voice-note.m4a")
        try data.write(to: url)
        let reads = FixtureValue(0)
        let fixture = try CoordinatorFixture(configureEnvironment: { environment in
            environment.chooseAudioToImport = { _ in url }
            // Only the picker and model are synthetic: native decoding/conversion is real.
            environment.readAudio = { url, policy in
                reads.update { $0 += 1 }
                return try AudioFileImporter.read(url, policy: policy)
            }
        })
        fixture.permissionStatus = .denied
        fixture.coordinator.importAudio(); await waitForOperation(fixture)
        XCTAssertEqual(reads.value, 1)
        XCTAssertEqual(fixture.coordinator.session.phase, .review)
        XCTAssertEqual(fixture.coordinator.editedText, fixture.inference.transcript)
        XCTAssertEqual(fixture.coordinator.session.rawTranscript, fixture.inference.transcript)
        let samples = fixture.inference.receivedPCM.value
        XCTAssertTrue((3500...5000).contains(samples.count))
        XCTAssertTrue(samples.allSatisfy(\.isFinite))
        let rms = sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count))
        XCTAssertTrue((0.03...0.15).contains(rms), "Model stub must receive the decoded tone")
        XCTAssertEqual(fixture.coordinator.metrics?.frames16k, samples.count)
        XCTAssertNotNil(fixture.coordinator.metrics?.audioPreparationSeconds)
        XCTAssertNotNil(fixture.coordinator.metrics?.audioImportTotalSeconds)
        XCTAssertEqual(fixture.inference.counts.value.loads, 1)
        XCTAssertEqual(fixture.inference.counts.value.decodes, 1)
        XCTAssertEqual(fixture.resources.counts.value.constructed, 0)
        XCTAssertEqual(fixture.permissionCalls, 0)
        XCTAssertEqual(fixture.coordinator.microphone.state, .closed)
        XCTAssertTrue(fixture.watchdog.handles.isEmpty)
        XCTAssertTrue(fixture.clipboard.calls.isEmpty)
        XCTAssertFalse(fixture.coordinator.canImportAudio)
        XCTAssertFalse(fixture.coordinator.audioFilePending)
        XCTAssertEqual(try Data(contentsOf: url), data)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [url.lastPathComponent])
    }
    func testBrokenCompressedHeadersFailWithoutModifyingInputOrCreatingStagingFiles() throws {
        let directory = try directory(), policy = try ResourcePolicy.bundled()
        for fixture in try fixtures() {
            let truncated = Data(try bytes(fixture).prefix(16))
            let url = directory.appendingPathComponent("broken-" + fixture.name + "." + fixture.extension)
            try truncated.write(to: url)
            XCTAssertThrowsError(try AudioFileImporter.read(url, policy: policy), fixture.extension)
            XCTAssertEqual(try Data(contentsOf: url), truncated)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 4)
    }
    func testSmallCompressedStreamCannotExceedActualDecodedDurationLimit() throws {
        let directory = try directory(), policy = try ResourcePolicy.bundled()
        let aac = try XCTUnwrap(fixtures().first { $0.extension == "aac" })
        let packetStream = try bytes(aac)
        // ADTS is a self-framed packet stream. Repeating the generated packets yields
        // > 120 s in < 1 MiB; output/frame caps must apply independently of file size.
        var long = Data(); long.reserveCapacity(packetStream.count * 500)
        for _ in 0..<500 { long.append(packetStream) }
        XCTAssertLessThan(long.count, 1024 * 1024)
        let url = directory.appendingPathComponent("long.aac"); try long.write(to: url)
        XCTAssertThrowsError(try AudioFileImporter.read(url, policy: policy)) { error in
            guard case AudioFileImporter.Failure.durationLimit = error else {
                return XCTFail("Expected actual decoded-frame limit, not unsupported-codec rejection: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: url), long)
    }
}
