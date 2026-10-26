import AudioToolbox
import Darwin
import Foundation
import XCTest
@testable import ClavuneCore

/// Generated WAV bytes only, never microphone/user audio or models.
final class AudioFileImporterTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clavune-audio-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }
    private func wav(rate: UInt32 = 16000, channels: UInt16 = 1, format: UInt16 = 1,
                     bits: UInt16 = 16, samples: Data) -> Data {
        var bytes = Data()
        func ascii(_ text: String) { bytes.append(contentsOf: text.utf8) }
        func u16(_ value: UInt16) { bytes.append(UInt8(value & 255)); bytes.append(UInt8(value >> 8)) }
        func u32(_ value: UInt32) {
            for shift in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8((value >> shift) & 255)) }
        }
        let block = channels * (bits / 8)
        let floating = format == 3
        ascii("RIFF"); u32(UInt32(36 + (floating ? 14 : 0) + samples.count))
        ascii("WAVEfmt "); u32(floating ? 18 : 16)
        u16(format); u16(channels); u32(rate); u32(rate * UInt32(block)); u16(block); u16(bits)
        if floating { u16(0); ascii("fact"); u32(4); u32(UInt32(samples.count) / UInt32(block)) }
        ascii("data"); u32(UInt32(samples.count)); bytes.append(samples)
        return bytes
    }
    private func write(_ bytes: Data, directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString + ".wav")
        try bytes.write(to: url); return url
    }
    func testMonoPCM16WAVUsesExistingConversionAndLeavesInputUnchanged() throws {
        let directory = try directory(), policy = try ResourcePolicy.bundled()
        var bytes = Data(), native = [Float]()
        for index in 0..<4800 {
            let value = Int16((sin(Double(index) * 0.03) * 16000).rounded())
            let unsigned = UInt16(bitPattern: value)
            bytes.append(UInt8(unsigned & 255)); bytes.append(UInt8(unsigned >> 8))
            native.append(Float(value) / 32768)
        }
        let source = wav(rate: 48000, samples: bytes), url = try write(source, directory: directory)
        let imported = try AudioFileImporter.read(url, policy: policy)
        let expected = try AudioConversion(sourceRate: 48000, policy: policy)
        for start in stride(from: 0, to: native.count, by: policy.maxNativeBlockFrames) {
            try native.withUnsafeBufferPointer { all in
                try expected.append(UnsafeBufferPointer(rebasing: all[start..<min(start + policy.maxNativeBlockFrames, all.count)]))
            }
        }
        let output = try expected.finish()
        XCTAssertEqual(imported.sampleRate, 16000)
        XCTAssertEqual(imported.samples.count, output.samples.count)
        for (a, b) in zip(imported.samples, output.samples) { XCTAssertEqual(a, b, accuracy: 0.000001) }
        XCTAssertEqual(try Data(contentsOf: url), source)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
    }
    func testMonoUnsigned8AndSigned24AndFloat32PCMFormats() throws {
        let directory = try directory(), policy = try ResourcePolicy.bundled()
        let inputs: [(UInt16, UInt16, Data)] = [
            (1, 8, Data(repeating: 128, count: 1600)),
            (1, 24, Data(repeating: 0, count: 1600 * 3)),
            (1, 32, Data(repeating: 0, count: 1600 * 4)),
            (3, 32, Data(repeating: 0, count: 1600 * 4))
        ]
        for (format, bits, samples) in inputs {
            let url = try write(wav(format: format, bits: bits, samples: samples), directory: directory)
            let pcm = try AudioFileImporter.read(url, policy: policy)
            XCTAssertEqual(pcm.samples.count, 1600)
            XCTAssertTrue(pcm.samples.allSatisfy { abs($0) < 0.000001 })
        }
    }
    func testMultichannelUnsupportedRateCompressedWAVAndInvalidFilesFailClosed() throws {
        let directory = try directory(), policy = try ResourcePolicy.bundled()
        for bytes in [wav(channels: 3, samples: Data(repeating: 0, count: 9600)),
                      wav(rate: 4000, samples: Data(repeating: 0, count: 800)),
                      wav(format: 6, bits: 8, samples: Data(repeating: 0, count: 1600)),
                      Data("not audio".utf8), wav(samples: Data())] {
            let url = try write(bytes, directory: directory)
            XCTAssertThrowsError(try AudioFileImporter.read(url, policy: policy))
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }
    func testStereoPCMUsesDisclosedMeanAndExistingRateConversion() throws {
        let directory = try directory(), policy = try ResourcePolicy.bundled()
        var bytes = Data(), expectedNative = [Float]()
        for index in 0..<4800 {
            let left = Int16((sin(Double(index) * 0.03) * 16000).rounded())
            let right = Int16(index % 2 == 0 ? 4000 : -2000)
            for value in [left, right] {
                let bits = UInt16(bitPattern: value)
                bytes.append(UInt8(bits & 255)); bytes.append(UInt8(bits >> 8))
            }
            expectedNative.append(Float(left) / 65536 + Float(right) / 65536)
        }
        let url = try write(wav(rate: 48000, channels: 2, samples: bytes), directory: directory)
        let imported = try AudioFileImporter.read(url, policy: policy)
        let converter = try AudioConversion(sourceRate: 48000, policy: policy)
        for start in stride(from: 0, to: expectedNative.count, by: policy.maxNativeBlockFrames) {
            try expectedNative.withUnsafeBufferPointer { all in
                try converter.append(UnsafeBufferPointer(rebasing: all[start..<min(start + policy.maxNativeBlockFrames, all.count)]))
            }
        }
        let expected = try converter.finish().samples
        XCTAssertEqual(imported.samples.count, expected.count)
        for (a, b) in zip(imported.samples, expected) { XCTAssertEqual(a, b, accuracy: 0.000001) }
    }
    func testStereoMeanHandlesAsymmetricCorrelatedAntiphaseAndNonfiniteSamples() throws {
        var samples: [Float] = [0.5, 0, 0.5, 0.5, 0.5, -0.5,
                                Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude]
        try samples.withUnsafeMutableBufferPointer { buffer in
            try AudioFileImporter.mixToMonoInPlace(buffer.baseAddress!, frames: 4, channels: 2)
        }
        XCTAssertEqual(Array(samples.prefix(3)), [0.25, 0.5, 0])
        XCTAssertEqual(samples[3], Float.greatestFiniteMagnitude)
        for bad: Float in [.nan, .infinity, -.infinity] {
            var invalid: [Float] = [0.1, bad]
            XCTAssertThrowsError(try invalid.withUnsafeMutableBufferPointer {
                try AudioFileImporter.mixToMonoInPlace($0.baseAddress!, frames: 1, channels: 2)
            })
        }
    }
    func testContainerCodecAllowlistDoesNotClaimAllAACProfilesOrEveryM4ACodec() {
        var format = AudioStreamBasicDescription()
        for (container, codec) in [(kAudioFileM4AType, kAudioFormatMPEG4AAC),
                                    (kAudioFileAAC_ADTSType, kAudioFormatMPEG4AAC),
                                    (kAudioFileM4AType, kAudioFormatAppleLossless),
                                    (kAudioFileMP3Type, kAudioFormatMPEGLayer3)] {
            format.mFormatID = codec
            XCTAssertTrue(AudioFileImporter.supports(type: container, format: format))
        }
        for (container, codec) in [(kAudioFileM4AType, kAudioFormatMPEG4AAC_HE),
                                    (kAudioFileAAC_ADTSType, kAudioFormatMPEG4AAC_HE_V2),
                                    (kAudioFileCAFType, kAudioFormatMPEG4AAC),
                                    (kAudioFileMP3Type, kAudioFormatLinearPCM)] {
            format.mFormatID = codec
            XCTAssertFalse(AudioFileImporter.supports(type: container, format: format))
        }
    }
    func testNonFiniteFloatSamplesAreRejectedByExistingConversion() throws {
        let directory = try directory(), policy = try ResourcePolicy.bundled()
        // Little-endian IEEE 754 NaN; no unsafe memory binding required in fixture.
        let url = try write(wav(format: 3, bits: 32, samples: Data([0, 0, 0xC0, 0x7F])), directory: directory)
        XCTAssertThrowsError(try AudioFileImporter.read(url, policy: policy))
    }
    func testExactDurationAcceptedAndOneFrameOverRejectedWithoutTruncation() throws {
        let directory = try directory(), policy = try ResourcePolicy.bundled()
        let atLimit = Data(repeating: 0, count: policy.maxSamples * 2)
        let url = try write(wav(samples: atLimit), directory: directory)
        XCTAssertEqual(try AudioFileImporter.read(url, policy: policy).samples.count, policy.maxSamples)
        let over = try write(wav(samples: atLimit + Data([0, 0])), directory: directory)
        XCTAssertThrowsError(try AudioFileImporter.read(over, policy: policy)) { error in
            guard case AudioFileImporter.Failure.durationLimit = error else { return XCTFail("Expected duration bound") }
        }
    }
    func testByteLimitUsesSparseFileAndSourceHasNoWriteAccess() throws {
        let directory = try directory(), url = try write(Data([0]), directory: directory)
        let file = try FileHandle(forWritingTo: url)
        try file.truncate(atOffset: UInt64(AudioFileImporter.maximumBytes)); try file.close()
        let source = try AudioFileReadSource(url)
        XCTAssertEqual(source.size, Int64(AudioFileImporter.maximumBytes)); source.close()
        let larger = try FileHandle(forWritingTo: url)
        try larger.truncate(atOffset: UInt64(AudioFileImporter.maximumBytes + 1)); try larger.close()
        XCTAssertThrowsError(try AudioFileReadSource(url)) { error in
            guard case AudioFileImporter.Failure.tooLarge = error else { return XCTFail("Expected byte bound") }
        }
    }
    func testNonFileURLMissingDirectorySymlinkAndFIFOAreRejectedWithoutBlocking() throws {
        let directory = try directory(), file = try write(Data([1, 2, 3]), directory: directory)
        let link = directory.appendingPathComponent("link.wav"), fifo = directory.appendingPathComponent("fifo.wav")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertEqual(mkfifo(fifo.path, mode_t(0o600)), 0)
        let urls = [try XCTUnwrap(URL(string: "https://example.invalid/audio.wav")), directory,
                    link, fifo, directory.appendingPathComponent("absent.wav")]
        for url in urls { XCTAssertThrowsError(try AudioFileReadSource(url)) }
    }
    func testDescriptorPinsFileAcrossReplacementAndClipsReadToOriginalSize() throws {
        let directory = try directory(), url = try write(Data([1, 2, 3]), directory: directory)
        let source = try AudioFileReadSource(url); defer { source.close() }
        let renamed = directory.appendingPathComponent("original.wav")
        try FileManager.default.moveItem(at: url, to: renamed)
        try Data([8, 9]).write(to: url)
        var bytes = [UInt8](repeating: 0, count: 16), actual: UInt32 = 0
        let status = bytes.withUnsafeMutableBytes { source.read(position: 0, requested: 16, buffer: $0.baseAddress!, actual: &actual) }
        XCTAssertEqual(status, noErr); XCTAssertEqual(actual, 3); XCTAssertEqual(Array(bytes.prefix(3)), [1, 2, 3])
        source.close(); source.close()
        XCTAssertNotEqual(bytes.withUnsafeMutableBytes { source.read(position: 0, requested: 1, buffer: $0.baseAddress!, actual: &actual) }, noErr)
    }
    func testConcurrentGrowthIsRejectedAndCannotExpandReadBoundary() throws {
        let directory = try directory(), url = try write(Data([1, 2, 3]), directory: directory)
        let source = try AudioFileReadSource(url); defer { source.close() }
        let writer = try FileHandle(forWritingTo: url); try writer.seekToEnd(); try writer.write(contentsOf: Data([4])); try writer.close()
        XCTAssertThrowsError(try source.requireUnchanged())
        var byte: UInt8 = 0, actual: UInt32 = 99
        XCTAssertEqual(source.read(position: 3, requested: 1, buffer: &byte, actual: &actual), noErr)
        XCTAssertEqual(actual, 0)
        XCTAssertNotEqual(source.read(position: -1, requested: 1, buffer: &byte, actual: &actual), noErr)
    }
    func testCancelledImportAndCallbackDoNotReadSyntheticBytes() async throws {
        let directory = try directory(), url = try write(wav(samples: Data([0, 0])), directory: directory)
        let policy = try ResourcePolicy.bundled()
        let operation = Task {
            let source = try AudioFileReadSource(url); defer { source.close() }
            withUnsafeCurrentTask { $0?.cancel() }
            XCTAssertThrowsError(try AudioFileImporter.read(url, policy: policy))
            var byte: UInt8 = 0, actual: UInt32 = 99
            XCTAssertNotEqual(source.read(position: 0, requested: 1, buffer: &byte, actual: &actual), noErr)
            XCTAssertEqual(actual, 0)
        }
        try await operation.value
    }
    func testImportedSessionTransitionRejectsStaleIdentityAndLateResults() throws {
        var session = SessionMachine()
        let old = try session.begin(); session.cancel()
        let current = try session.begin()
        XCTAssertFalse(session.transcribingImportedAudio(old))
        XCTAssertTrue(session.transcribingImportedAudio(current))
        XCTAssertFalse(session.transcribingImportedAudio(current))
        session.result("stale", session: old); XCTAssertEqual(session.rawTranscript, "")
        session.result("imported", session: current); XCTAssertEqual(session.phase, .review)
        XCTAssertEqual(session.rawTranscript, "imported")
    }
}
