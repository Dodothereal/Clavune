import AudioToolbox
import Darwin
import Foundation

/// Explicit, read-only WAV, M4A (AAC-LC/ALAC), ADTS AAC-LC and MP3 import. No copy, path retention, microphone or background work.
/// Call on a worker. The descriptor pins the chosen regular file across path replacement.
public enum AudioFileImporter {
    public static let maximumBytes = 64 * 1024 * 1024
    public enum Failure: Error { case invalidFile, tooLarge, unsupportedFormat, durationLimit, noAudio, changedFile }

    public static func read(_ url: URL, policy: ResourcePolicy) throws -> SessionPCM {
        try Task.checkCancellation()
        guard policy.sampleRate == 16000, (1...120).contains(policy.sessionLimitSeconds),
              (128...16384).contains(policy.maxNativeBlockFrames) else { throw DictationError.configuration }
        let source = try AudioFileReadSource(url)
        defer { source.close() }
        var opened: AudioFileID?
        let status = AudioFileOpenWithCallbacks(Unmanaged.passUnretained(source).toOpaque(),
            { context, position, requested, buffer, actual in
                Unmanaged<AudioFileReadSource>.fromOpaque(context).takeUnretainedValue()
                    .read(position: position, requested: requested, buffer: buffer, actual: actual)
            }, nil, { context in
                Unmanaged<AudioFileReadSource>.fromOpaque(context).takeUnretainedValue().size
            }, nil, 0, &opened)
        guard status == noErr, let file = opened else {
            if let opened { AudioFileClose(opened) }
            throw Failure.unsupportedFormat
        }
        defer { AudioFileClose(file) }
        try Task.checkCancellation()
        var type: AudioFileTypeID = 0
        var size = UInt32(MemoryLayout.size(ofValue: type))
        guard AudioFileGetProperty(file, kAudioFilePropertyFileFormat, &size, &type) == noErr else {
            throw Failure.unsupportedFormat
        }
        var wrapped: ExtAudioFileRef?
        let wrappedStatus = ExtAudioFileWrapAudioFileID(file, false, &wrapped)
        guard wrappedStatus == noErr, let reader = wrapped else {
            if let wrapped { ExtAudioFileDispose(wrapped) }
            throw Failure.unsupportedFormat
        }
        // Wrapping does not transfer AudioFileID ownership. Dispose wrapper first.
        defer { ExtAudioFileDispose(reader) }
        var format = AudioStreamBasicDescription()
        size = UInt32(MemoryLayout.size(ofValue: format))
        guard ExtAudioFileGetProperty(reader, kExtAudioFileProperty_FileDataFormat, &size, &format) == noErr,
              supports(type: type, format: format),
              (1...2).contains(format.mChannelsPerFrame),
              format.mSampleRate.isFinite, (8000...192000).contains(format.mSampleRate)
        else { throw Failure.unsupportedFormat }
        let channels = Int(format.mChannelsPerFrame)
        let frameLimit = Int64(format.mSampleRate * Double(policy.sessionLimitSeconds))
        let isPCM = format.mFormatID == kAudioFormatLinearPCM
        var declaredFrames: Int64 = 0
        if isPCM {
            size = UInt32(MemoryLayout.size(ofValue: declaredFrames))
            guard ExtAudioFileGetProperty(reader, kExtAudioFileProperty_FileLengthFrames, &size, &declaredFrames) == noErr,
                  declaredFrames > 0 else { throw Failure.noAudio }
            guard declaredFrames <= frameLimit else { throw Failure.durationLimit }
        } else {
            // Compressed packet counts can include priming/padding. Use explicit
            // valid-frame metadata for early rejection when present, never a guessed
            // equality with raw packet frames. Actual decoded frames are always capped.
            var table = AudioFilePacketTableInfo()
            size = UInt32(MemoryLayout.size(ofValue: table))
            if AudioFileGetProperty(file, kAudioFilePropertyPacketTableInfo, &size, &table) == noErr {
                guard table.mNumberValidFrames >= 0 else { throw Failure.invalidFile }
                guard table.mNumberValidFrames <= frameLimit else { throw Failure.durationLimit }
            }
        }
        var client = AudioStreamBasicDescription(mSampleRate: format.mSampleRate,
            mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
            mBytesPerPacket: UInt32(channels * 4), mFramesPerPacket: 1, mBytesPerFrame: UInt32(channels * 4),
            mChannelsPerFrame: format.mChannelsPerFrame, mBitsPerChannel: 32, mReserved: 0)
        // Keep the native sample rate and channels while decoding. No hidden native
        // downmix/rate stage: the explicit mean below precedes existing AudioConversion.
        guard ExtAudioFileSetProperty(reader, kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout.size(ofValue: client)), &client) == noErr else { throw Failure.unsupportedFormat }
        let conversion = try AudioConversion(sourceRate: format.mSampleRate, policy: policy)
        let capacity = policy.maxNativeBlockFrames
        let samples = UnsafeMutablePointer<Float>.allocate(capacity: capacity * channels)
        defer { samples.deallocate() }
        var consumed: Int64 = 0
        while true {
            try Task.checkCancellation()
            var count = UInt32(capacity)
            var buffers = AudioBufferList(mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(capacity * channels * 4), mData: samples))
            guard ExtAudioFileRead(reader, &count, &buffers) == noErr else { throw Failure.invalidFile }
            guard Int(count) <= capacity else { throw Failure.invalidFile }
            if count == 0 { break }
            consumed += Int64(count)
            guard consumed <= frameLimit else { throw Failure.durationLimit }
            if isPCM, consumed > declaredFrames { throw Failure.changedFile }
            try mixToMonoInPlace(samples, frames: Int(count), channels: channels)
            try conversion.append(UnsafeBufferPointer(start: samples, count: Int(count)))
        }
        guard consumed > 0 else { throw Failure.noAudio }
        if isPCM, consumed != declaredFrames { throw Failure.changedFile }
        try source.requireUnchanged()
        try Task.checkCancellation()
        let pcm = try conversion.finish()
        try Task.checkCancellation()
        return pcm
    }

    static func supports(type: AudioFileTypeID, format: AudioStreamBasicDescription) -> Bool {
        switch type {
        case kAudioFileWAVEType:
            return format.mFormatID == kAudioFormatLinearPCM &&
                [8, 16, 24, 32].contains(format.mBitsPerChannel) &&
                (format.mFormatFlags & kAudioFormatFlagIsFloat == 0 || format.mBitsPerChannel == 32)
        case kAudioFileM4AType:
            return [kAudioFormatMPEG4AAC, kAudioFormatAppleLossless].contains(format.mFormatID)
        case kAudioFileAAC_ADTSType:
            return format.mFormatID == kAudioFormatMPEG4AAC // AAC-LC; HE/other profiles are not claimed.
        case kAudioFileMP3Type:
            return format.mFormatID == kAudioFormatMPEGLayer3
        default:
            return false
        }
    }
    /// Fixed, disclosed stereo mean. Phase-inverted stereo may cancel; no channel inference.
    /// Compaction reuses the input block; writes never overlap unread interleaved frames.
    static func mixToMonoInPlace(_ samples: UnsafeMutablePointer<Float>, frames: Int, channels: Int) throws {
        guard frames >= 0, (1...2).contains(channels) else { throw Failure.unsupportedFormat }
        if channels == 1 { return } // Existing AudioConversion validates mono once; no duplicate scan.
        for index in 0..<frames {
            let left = samples[index * channels]
            guard left.isFinite else { throw Failure.unsupportedFormat }
            if channels == 2 {
                let right = samples[index * 2 + 1]
                guard right.isFinite else { throw Failure.unsupportedFormat }
                samples[index] = left * 0.5 + right * 0.5
            }
        }
    }
}

/// Synchronous callbacks only, with bounded cumulative reads even for malformed metadata.
/// Internal visibility allows synthetic descriptor/race tests without a real model or user file.
final class AudioFileReadSource {
    private var descriptor: Int32
    private let original: stat
    let size: Int64
    private var remainingReadBytes = AudioFileImporter.maximumBytes * 4

    init(_ url: URL) throws {
        guard url.isFileURL else { throw AudioFileImporter.Failure.invalidFile }
        let opened = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC) } ?? -1
        }
        guard opened >= 0 else { throw AudioFileImporter.Failure.invalidFile }
        var info = stat()
        guard fstat(opened, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), info.st_size > 0 else {
            Darwin.close(opened); throw AudioFileImporter.Failure.invalidFile
        }
        guard info.st_size <= off_t(AudioFileImporter.maximumBytes) else {
            Darwin.close(opened); throw AudioFileImporter.Failure.tooLarge
        }
        descriptor = opened; original = info; size = Int64(info.st_size)
    }
    deinit { close() }
    func close() { if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 } }
    func read(position: Int64, requested: UInt32, buffer: UnsafeMutableRawPointer,
              actual: UnsafeMutablePointer<UInt32>) -> OSStatus {
        actual.pointee = 0
        guard !Task.isCancelled, descriptor >= 0, position >= 0, position <= size else {
            return kAudioFileUnspecifiedError
        }
        let count = min(Int64(requested), size - position)
        guard count <= Int64(remainingReadBytes) else { return kAudioFileUnspecifiedError }
        remainingReadBytes -= Int(count)
        let read = pread(descriptor, buffer, Int(count), off_t(position))
        guard read >= 0 else { return kAudioFileUnspecifiedError }
        actual.pointee = UInt32(read)
        return noErr
    }
    func requireUnchanged() throws {
        var current = stat()
        guard descriptor >= 0, fstat(descriptor, &current) == 0,
              current.st_size == original.st_size,
              current.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec,
              current.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec,
              current.st_ctimespec.tv_sec == original.st_ctimespec.tv_sec,
              current.st_ctimespec.tv_nsec == original.st_ctimespec.tv_nsec else {
            throw AudioFileImporter.Failure.changedFile
        }
    }
}
