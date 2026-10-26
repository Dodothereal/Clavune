import Darwin
import Foundation

/// Explicit UTF-8 transcript files only. No history, path retention, or background work.
public enum TranscriptFileStore {
    public static let maximumBytes = 4 * 1024 * 1024
    public enum Failure: Error { case invalidFile, tooLarge, invalidUTF8 }

    public static func read(_ url: URL) throws -> String {
        try Task.checkCancellation()
        guard url.isFileURL else { throw Failure.invalidFile }
        // Refuse special files and final-component symlinks without a blocking open.
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC) } ?? -1
        }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw Failure.invalidFile
        }
        guard info.st_size <= off_t(maximumBytes) else { throw Failure.tooLarge }
        var data = Data()
        // The extra byte detects growth after fstat. Allocation stays bounded even
        // for a concurrently growing file; an empty UTF-8 file is a valid review.
        while data.count <= maximumBytes {
            try Task.checkCancellation()
            let count = min(64 * 1024, maximumBytes + 1 - data.count)
            guard let chunk = try file.read(upToCount: count), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= maximumBytes else { throw Failure.tooLarge }
        try Task.checkCancellation()
        guard let text = String(data: data, encoding: .utf8) else { throw Failure.invalidUTF8 }
        return text
    }

    public static func write(_ text: String, to url: URL) throws {
        try Task.checkCancellation()
        guard url.isFileURL else { throw Failure.invalidFile }
        guard text.utf8.count <= maximumBytes else { throw Failure.tooLarge }
        // Never write through a link or into a device/directory. Rename below
        // replaces the chosen path itself, not a last-component symlink target.
        var info = stat()
        let status = url.withUnsafeFileSystemRepresentation { path in
            path.map { lstat($0, &info) } ?? -1
        }
        if status == 0 {
            guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { throw Failure.invalidFile }
        } else if errno != ENOENT { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        // An exclusive 0600 sibling stays on the destination volume for atomic
        // rename. Failures/cancellation remove only this invocation's own staging file.
        var template = Array(url.deletingLastPathComponent()
            .appendingPathComponent(".clavune-transcript-XXXXXX").path.utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let temporary = String(cString: template)
        var committed = false
        defer { if !committed { _ = unlink(temporary) } }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        try file.write(contentsOf: Data(text.utf8))
        try file.synchronize()
        try file.close()
        try Task.checkCancellation()
        // The atomic commit cannot be rolled back by a later cancellation.
        let renamed = url.withUnsafeFileSystemRepresentation { path in
            path.map { rename(temporary, $0) } ?? -1
        }
        guard renamed == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        committed = true
    }
}
