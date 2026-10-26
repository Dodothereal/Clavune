import Darwin
import Foundation

public enum ModelDownloadFailure: Error, LocalizedError, Equatable, Sendable {
    case unavailableSource, invalidSource, insufficientStorage, unsafePartial
    case rejectedResponse, invalidRedirect, incompleteTransfer, transferTooLarge
    case changedSource

    public var errorDescription: String? {
        switch self {
        case .unavailableSource: return "Für dieses Modell gibt es keine geprüfte Downloadquelle."
        case .invalidSource: return "Die Downloadquelle passt nicht zum festgelegten Modellmanifest."
        case .insufficientStorage: return "Es ist nicht genügend bestätigter Speicherplatz für dieses Modell verfügbar."
        case .unsafePartial: return "Der unvollständige Modelldownload ließ sich nicht sicher fortsetzen; die Dateien bleiben erhalten."
        case .rejectedResponse: return "Der Modellserver hat eine unerwartete Antwort zurückgegeben."
        case .invalidRedirect: return "Der Download wurde zu einem nicht zugelassenen HTTPS-Server umgeleitet."
        case .incompleteTransfer: return "Der Modelldownload wurde vorzeitig unterbrochen. Geprüfte Teildaten bleiben erhalten."
        case .transferTooLarge: return "Der Server hat mehr Daten als für das Modell zugelassen gesendet."
        case .changedSource: return "Die festgelegte Modellquelle hat sich während des fortgesetzten Downloads geändert."
        }
    }
}

/// Explicit, bounded download of catalogued model bytes. The endpoint is pinned
/// to a repository commit; the final file is size/hash verified before activation.
public enum ModelDownloadService {
    /// Explicit Hugging Face Hub model-byte delivery hosts. Exact hosts
    /// avoid sending connection metadata to an arbitrary HTTPS redirect target.
    private static let redirectHosts: Set<String> = [
        "huggingface.co",
        "cdn-lfs.huggingface.co",
        "cas-bridge.xethub.hf.co",
        "transfer.xethub.hf.co"
    ]

    static func permitsRedirect(to url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return redirectHosts.contains(host)
    }

    public static func download(
        _ candidate: ModelCandidate,
        into directory: URL,
        sessionConfiguration: URLSessionConfiguration = .ephemeral,
        progress: @escaping @Sendable (Int64) -> Void = { _ in }
    ) async throws -> ModelStore.Installed {
        try await download(candidate, into: directory, sessionConfiguration: sessionConfiguration,
                           progress: progress, beforeInstallTask: nil, beforeActivation: nil)
    }

    // The final synchronous hook is an internal deterministic cancellation seam
    // for tests; production callers use the public overload above.
    static func download(
        _ candidate: ModelCandidate,
        into directory: URL,
        sessionConfiguration: URLSessionConfiguration,
        progress: @escaping @Sendable (Int64) -> Void,
        beforeInstallTask: (@Sendable () -> Void)? = nil,
        beforeActivation: (@Sendable () throws -> Void)?
    ) async throws -> ModelStore.Installed {
        guard candidate.downloadEnabled else { throw ModelDownloadFailure.unavailableSource }
        let source = try pinnedSource(for: candidate)
        try prepare(directory)

        let installedURL = directory.appendingPathComponent(candidate.sha256 + ".bin")
        if FileManager.default.fileExists(atPath: installedURL.path) {
            do {
                _ = try ModelStore.verify(installedURL, candidates: [candidate])
                return ModelStore.Installed(url: installedURL, candidate: candidate, reusedVerifiedFile: true)
            } catch DictationError.modelMismatch {
                // ModelStore preserves an invalid prior file as its one recovery backup.
            }
        }

        let part = directory.appendingPathComponent(".download-\(candidate.sha256).part")
        let available = try freeCapacity(at: directory)
        let received = try existingPartSize(part, candidate: candidate, source: source)
        guard available >= candidate.sizeBytes - received else { throw ModelDownloadFailure.insufficientStorage }

        let transfer = try ModelDownloadTransfer(candidate: candidate, source: source,
                                                  directory: directory, configuration: sessionConfiguration,
                                                  progress: progress)
        let completed = try await withTaskCancellationHandler {
            try await transfer.perform()
        } onCancel: {
            transfer.cancel()
        }

        let installTaskHandoff = ModelDownloadInstallTaskHandoff()
        do {
            let installed = try await withTaskCancellationHandler {
                beforeInstallTask?()
                let installTask = Task.detached(priority: .utility) {
                    // Do not let verification start until this task is attached
                    // to the cancellation handoff. Cancellation can otherwise
                    // race between task creation and registration.
                    await installTaskHandoff.waitUntilStarted()
                    try Task.checkCancellation()
                    return try ModelStore.installVerifiedDownload(completed, candidate: candidate,
                        into: directory, beforeActivation: beforeActivation)
                }
                // Cancellation may race before or during this registration. The
                // handoff remembers early cancellation and cancels late attachment.
                installTaskHandoff.attach(installTask)
                installTaskHandoff.start()
                return try await installTask.value
            } onCancel: {
                installTaskHandoff.cancel()
            }
            try? FileManager.default.removeItem(at: transfer.recordURL)
            // The part may have been renamed into its final model path.
            try? FileManager.default.removeItem(at: completed)
            return installed
        } catch DictationError.modelMismatch {
            // A completed but untrusted payload is never kept as resumable data.
            try? FileManager.default.removeItem(at: completed)
            try? FileManager.default.removeItem(at: transfer.recordURL)
            throw DictationError.modelMismatch
        }
    }

    private static func pinnedSource(for candidate: ModelCandidate) throws -> URL {
        guard let url = candidate.sourceURL, let revision = candidate.sourceRevision,
              candidate.sizeBytes > 0, candidate.license == "MIT",
              candidate.sha256.count == 64,
              candidate.sha256.allSatisfy({ "0123456789abcdef".contains($0) }),
              revision.count == 40,
              revision.allSatisfy({ "0123456789abcdef".contains($0) }),
              url.scheme == "https", url.host == "huggingface.co", url.user == nil,
              url.password == nil, url.port == nil, url.fragment == nil,
              url.path == "/ggerganov/whisper.cpp/resolve/\(revision)/\(candidate.fileName)"
        else { throw ModelDownloadFailure.invalidSource }
        return url
    }

    private static func prepare(_ directory: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: directory.path) {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw ModelDownloadFailure.unsafePartial
            }
        } else {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        }
    }

    private static func freeCapacity(at directory: URL) throws -> Int64 {
        let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                              .volumeAvailableCapacityKey])
        let capacity: Int64?
        if let important = values.volumeAvailableCapacityForImportantUsage {
            capacity = important
        } else if let available = values.volumeAvailableCapacity {
            capacity = Int64(available)
        } else {
            capacity = nil
        }
        guard let capacity, capacity >= 0 else { throw ModelDownloadFailure.insufficientStorage }
        return capacity
    }

    private static func existingPartSize(_ part: URL, candidate: ModelCandidate,
                                         source: URL) throws -> Int64 {
        let manager = FileManager.default
        let record = part.appendingPathExtension("json")
        let partExists = manager.fileExists(atPath: part.path)
        let recordExists = manager.fileExists(atPath: record.path)
        guard partExists == recordExists else { throw ModelDownloadFailure.unsafePartial }
        guard partExists else { return 0 }
        let values = try part.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        let recordValues = try record.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              recordValues.isRegularFile == true, recordValues.isSymbolicLink != true,
              let size = values.fileSize, size >= 0, Int64(size) <= candidate.sizeBytes else {
            throw ModelDownloadFailure.unsafePartial
        }
        let saved = try JSONDecoder().decode(ModelDownloadTransfer.ResumeRecord.self, from: Data(contentsOf: record))
        guard saved.sha256 == candidate.sha256, saved.fileName == candidate.fileName,
              saved.sourceURL == source.absoluteString else { throw ModelDownloadFailure.unsafePartial }
        // A complete object is rehashed by ModelStore before activation and never
        // needs an HTTP append. An incomplete object still needs a strong validator
        // before any byte can be reused with a Range request.
        if Int64(size) == candidate.sizeBytes { return Int64(size) }
        return ModelDownloadTransfer.hasStrongETag(saved.eTag) ? Int64(size) : 0
    }
}

/// Bridges cancellation that can arrive before a detached verifier is attached.
private final class ModelDownloadInstallTaskHandoff: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<ModelStore.Installed, Error>?
    private var cancellationRequested = false
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var started = false

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            guard !started else {
                lock.unlock()
                continuation.resume()
                return
            }
            startContinuation = continuation
            lock.unlock()
        }
    }

    func attach(_ task: Task<ModelStore.Installed, Error>) {
        lock.lock()
        self.task = task
        let cancel = cancellationRequested
        lock.unlock()
        if cancel { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    func start() {
        lock.lock()
        started = true
        let continuation = startContinuation
        startContinuation = nil
        let task = self.task
        let cancel = cancellationRequested
        lock.unlock()
        if cancel { task?.cancel() }
        continuation?.resume()
    }
}

// Internal only so lifecycle tests can observe transfer release without a live request.
final class ModelDownloadTransfer: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    fileprivate struct ResumeRecord: Codable {
        let sha256: String
        let fileName: String
        let sourceURL: String
        var eTag: String?
    }

    private let candidate: ModelCandidate
    private let source: URL
    private let partURL: URL
    let recordURL: URL
    private let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var currentTask: URLSessionDataTask?
    private var cancelRequested = false
    private var finished = false
    private let configuration: URLSessionConfiguration
    private var session: URLSession?
    private var file: FileHandle?
    private var received: Int64
    private var requestedOffset: Int64
    private var savedETag: String?
    private var responseFailure: Error?
    private var responseAccepted = false
    private var lastProgressBytes: Int64 = 0

    init(candidate: ModelCandidate, source: URL, directory: URL,
         configuration suppliedConfiguration: URLSessionConfiguration,
         progress: @escaping @Sendable (Int64) -> Void) throws {
        self.candidate = candidate; self.source = source; self.progress = progress
        configuration = suppliedConfiguration.copy() as! URLSessionConfiguration
        partURL = directory.appendingPathComponent(".download-\(candidate.sha256).part")
        recordURL = partURL.appendingPathExtension("json")
        let manager = FileManager.default
        var createdPart = false
        var restartWithoutValidator = false
        if manager.fileExists(atPath: partURL.path) {
            let partValues = try partURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            let recordValues = try recordURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard partValues.isRegularFile == true, partValues.isSymbolicLink != true,
                  recordValues.isRegularFile == true, recordValues.isSymbolicLink != true else {
                throw ModelDownloadFailure.unsafePartial
            }
            let record = try JSONDecoder().decode(ResumeRecord.self, from: Data(contentsOf: recordURL))
            savedETag = record.eTag
            let attributes = try manager.attributesOfItem(atPath: partURL.path)
            received = (attributes[.size] as? NSNumber)?.int64Value ?? -1
            guard record.sha256 == candidate.sha256, record.fileName == candidate.fileName,
                  record.sourceURL == source.absoluteString, received >= 0,
                  received <= candidate.sizeBytes else { throw ModelDownloadFailure.unsafePartial }
            if received > 0 && received < candidate.sizeBytes && !Self.hasStrongETag(savedETag) {
                let handle = try FileHandle(forWritingTo: partURL)
                try handle.truncate(atOffset: 0)
                try handle.close()
                received = 0
                savedETag = nil
                restartWithoutValidator = true
            }
        } else {
            received = 0
            let descriptor = partURL.path.withCString {
                open($0, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            }
            guard descriptor >= 0 else { throw ModelDownloadFailure.unsafePartial }
            _ = close(descriptor)
            createdPart = true
            savedETag = nil
        }
        requestedOffset = received
        super.init()
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        if createdPart || restartWithoutValidator {
            do { try writeRecord() }
            catch {
                try? manager.removeItem(at: partURL)
                throw error
            }
        }
    }

    func perform() async throws -> URL {
        if received == candidate.sizeBytes { return partURL }
        // Finish all throwing pre-request setup before creating the session,
        // which retains its delegate even when no data task has been created.
        let openedFile = try FileHandle(forWritingTo: partURL)
        do { try openedFile.seekToEnd() }
        catch { try? openedFile.close(); throw error }
        file = openedFile
        let queue = OperationQueue()
        queue.name = "Clavune model transfer"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session = session
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            let wasCancelled = cancelRequested
            var request = URLRequest(url: source, cachePolicy: .reloadIgnoringLocalCacheData,
                                     timeoutInterval: 60)
            request.httpShouldHandleCookies = false
            if requestedOffset > 0 {
                request.setValue("bytes=\(requestedOffset)-", forHTTPHeaderField: "Range")
                if let savedETag { request.setValue(savedETag, forHTTPHeaderField: "If-Range") }
            }
            let task = session.dataTask(with: request)
            currentTask = task
            lock.unlock()
            if wasCancelled { task.cancel() } else { task.resume() }
        }
    }

    func cancel() {
        lock.lock()
        cancelRequested = true
        let task = currentTask
        lock.unlock()
        task?.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, ModelDownloadService.permitsRedirect(to: url) else {
            responseFailure = ModelDownloadFailure.invalidRedirect
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            responseFailure = ModelDownloadFailure.rejectedResponse
            completionHandler(.cancel); return
        }
        let etag = http.value(forHTTPHeaderField: "ETag")
        if http.statusCode == 200 {
            if requestedOffset > 0 {
                do {
                    try file?.truncate(atOffset: 0)
                    try file?.seek(toOffset: 0)
                } catch {
                    responseFailure = error; completionHandler(.cancel); return
                }
                received = 0; requestedOffset = 0; savedETag = nil
                progress(0)
            }
        } else if http.statusCode == 206, requestedOffset > 0 {
            guard let header = http.value(forHTTPHeaderField: "Content-Range"),
                  Self.range(header, startsAt: requestedOffset, total: candidate.sizeBytes) else {
                responseFailure = ModelDownloadFailure.rejectedResponse
                completionHandler(.cancel); return
            }
            guard Self.hasStrongETag(savedETag), Self.hasStrongETag(etag), savedETag == etag else {
                responseFailure = ModelDownloadFailure.changedSource
                completionHandler(.cancel); return
            }
        } else {
            responseFailure = ModelDownloadFailure.rejectedResponse
            completionHandler(.cancel); return
        }
        let remaining = candidate.sizeBytes - received
        let declaredLength = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init)
        if (declaredLength != nil && declaredLength != remaining) ||
            (http.expectedContentLength > 0 && http.expectedContentLength != remaining) {
            responseFailure = ModelDownloadFailure.rejectedResponse
            completionHandler(.cancel); return
        }
        // A full 200 response replaces the entity, even when it omits a strong
        // validator. Never attach an earlier zero-byte record's ETag to new bytes.
        if http.statusCode == 200 { savedETag = etag }
        do { try writeRecord() } catch {
            responseFailure = error; completionHandler(.cancel); return
        }
        responseAccepted = true
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard responseFailure == nil else { return }
        guard Int64(data.count) <= candidate.sizeBytes - received else {
            responseFailure = ModelDownloadFailure.transferTooLarge
            dataTask.cancel(); return
        }
        do {
            try file?.write(contentsOf: data)
            received += Int64(data.count)
            if received - lastProgressBytes >= 1024 * 1024 || received == candidate.sizeBytes {
                lastProgressBytes = received
                progress(received)
            }
        } catch {
            responseFailure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let responseFailure { finish(.failure(responseFailure)); return }
        if let error {
            lock.lock(); let wasCancelled = cancelRequested; lock.unlock()
            finish(.failure(wasCancelled ? CancellationError() : error)); return
        }
        guard responseAccepted else { finish(.failure(ModelDownloadFailure.rejectedResponse)); return }
        guard received == candidate.sizeBytes else {
            finish(.failure(ModelDownloadFailure.incompleteTransfer)); return
        }
        finish(.success(partURL))
    }

    private func finish(_ result: Result<URL, Error>) {
        try? file?.close(); file = nil
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil; currentTask = nil
        lock.unlock()
        session?.finishTasksAndInvalidate()
        if let continuation {
            switch result {
            case .success(let url): continuation.resume(returning: url)
            case .failure(let error): continuation.resume(throwing: error)
            }
        }
    }

    private func writeRecord() throws {
        let record = ResumeRecord(sha256: candidate.sha256, fileName: candidate.fileName,
                                  sourceURL: source.absoluteString, eTag: savedETag)
        try JSONEncoder().encode(record).write(to: recordURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordURL.path)
    }

    private static func range(_ header: String, startsAt offset: Int64, total: Int64) -> Bool {
        let pieces = header.replacingOccurrences(of: "bytes ", with: "").split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 2, Int64(pieces[1]) == total else { return false }
        let bounds = pieces[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]) else { return false }
        return start == offset && end == total - 1 && end >= start
    }

    static func hasStrongETag(_ value: String?) -> Bool {
        guard let value else { return false }
        let bytes = Array(value.utf8)
        guard bytes.count >= 2, bytes.first == 0x22, bytes.last == 0x22 else { return false }
        return bytes.dropFirst().dropLast().allSatisfy { $0 == 0x21 || (0x23...0x7e).contains($0) || $0 >= 0x80 }
    }
}
