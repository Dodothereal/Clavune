import AppKit
import Darwin

/// Explicit own-view evidence export inside the isolated synthetic QA process.
/// It never reads another window, display, microphone or system audio. The PNG
/// is rendered content, not a WindowServer screenshot or animation evidence.
@MainActor
enum QAEvidenceCapture {
    enum Failure: Error {
        case wrongBundle, missingMainWindow
        case invalidSize, encoding, unsafeDirectory, writeFailed
    }

    /// AppKit renders only this app's synthetic main content view. This is
    /// deliberately labeled rendered content, not a WindowServer screenshot.
    static func renderMainContent() throws -> URL {
        guard AppLaunchConfiguration.isStableComparisonBundle else { throw Failure.wrongBundle }
        let windows = NSApp.windows.filter {
            ["main", "clavune.main"].contains($0.identifier?.rawValue ?? "") &&
                $0.isVisible && !$0.isMiniaturized && $0.windowNumber > 0
        }
        guard windows.count == 1, let view = windows.first?.contentView else {
            throw Failure.missingMainWindow
        }
        let bounds = view.bounds
        guard bounds.width.isFinite, bounds.height.isFinite,
              bounds.width >= 1, bounds.width <= 4096,
              bounds.height >= 1, bounds.height <= 4096,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: bounds)
        else { throw Failure.invalidSize }
        view.cacheDisplay(in: bounds, to: bitmap)
        guard let bytes = bitmap.representation(using: .png, properties: [:]) else {
            throw Failure.encoding
        }
        return try storePNG(bytes, prefix: "rendered-content")
    }

    private static func storePNG(_ bytes: Data, prefix: String) throws -> URL {
        let directory = URL(fileURLWithPath: "/tmp/clavune-observatory-qa-evidence", isDirectory: true)
        // Inspect the name without following links before creating or writing.
        // The fixed directory makes evidence discoverable without a save panel.
        var directoryInfo = stat()
        if lstat(directory.path, &directoryInfo) != 0 {
            guard errno == ENOENT, mkdir(directory.path, 0o700) == 0 else {
                throw Failure.unsafeDirectory
            }
        }
        let directoryFD = Darwin.open(directory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw Failure.unsafeDirectory }
        defer { Darwin.close(directoryFD) }
        var openedDirectory = stat()
        guard lstat(directory.path, &directoryInfo) == 0,
              fstat(directoryFD, &openedDirectory) == 0,
              directoryInfo.st_dev == openedDirectory.st_dev,
              directoryInfo.st_ino == openedDirectory.st_ino,
              openedDirectory.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              openedDirectory.st_uid == geteuid(),
              openedDirectory.st_mode & 0o7777 == 0o700,
              hasNoExtendedACL(directoryFD)
        else { throw Failure.unsafeDirectory }
        let name = prefix + "-" + UUID().uuidString + ".png"
        let file = directory.appendingPathComponent(name)
        let fd = name.withCString {
            Darwin.openat(directoryFD, $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard fd >= 0 else { throw Failure.writeFailed }
        defer { close(fd) }
        var openedFile = stat()
        guard fstat(fd, &openedFile) == 0,
              openedFile.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              openedFile.st_uid == geteuid(),
              openedFile.st_mode & 0o7777 == 0o600,
              hasNoExtendedACL(fd)
        else { throw Failure.writeFailed }
        try bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { throw Failure.writeFailed }
            var written = 0
            while written < raw.count {
                let count = Darwin.write(fd, base.advanced(by: written), raw.count - written)
                guard count > 0 else { throw Failure.writeFailed }
                written += count
            }
        }
        guard fsync(fd) == 0 else { throw Failure.writeFailed }
        // Return a pathname only while it still names the pinned private directory.
        var currentDirectory = stat()
        guard lstat(directory.path, &currentDirectory) == 0,
              currentDirectory.st_dev == openedDirectory.st_dev,
              currentDirectory.st_ino == openedDirectory.st_ino
        else { throw Failure.unsafeDirectory }
        return file
    }

    private static func hasNoExtendedACL(_ fd: Int32) -> Bool {
        errno = 0
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
            return errno == ENOENT
        }
        acl_free(UnsafeMutableRawPointer(acl))
        return false
    }
}
