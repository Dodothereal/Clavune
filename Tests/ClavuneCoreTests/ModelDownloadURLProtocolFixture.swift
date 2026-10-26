import Foundation
@testable import ClavuneCore

/// In-process URLSession fixture. It never opens a socket or contacts the
/// catalogue's HTTPS origin.
final class ModelDownloadURLProtocol: URLProtocol, @unchecked Sendable {
    private let lifecycleLock = NSLock()
    private var loadingStopped = false
    private var pendingFailureGate: ModelDownloadFailureGate?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let plan = try ModelDownloadProtocolFixture.next(for: request)
            lifecycleLock.lock()
            guard !loadingStopped else {
                lifecycleLock.unlock(); plan.failureGate?.cancel(); return
            }
            pendingFailureGate = plan.failureGate
            lifecycleLock.unlock()
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: plan.status,
                    httpVersion: "HTTP/1.1", headerFields: plan.headers) else {
                throw ModelDownloadFailure.rejectedResponse
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in plan.chunks { client?.urlProtocol(self, didLoad: chunk) }
            if let error = plan.errorAfterChunks {
                let fail: @Sendable () -> Void = { [weak self] in
                    guard let self else { return }
                    self.lifecycleLock.lock()
                    let stopped = self.loadingStopped
                    self.lifecycleLock.unlock()
                    guard !stopped else { return }
                    self.client?.urlProtocol(self, didFailWithError: error)
                }
                if let gate = plan.failureGate {
                    // Only the test's explicit writer acknowledgement releases
                    // this failure. No elapsed time stands in for body delivery.
                    gate.arm(fail)
                } else {
                    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(50), execute: fail)
                }
            } else if plan.hangAfterChunks {
                // The test cancels the owning URLSessionTask after receiving data.
            } else {
                client?.urlProtocolDidFinishLoading(self)
            }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {
        lifecycleLock.lock()
        loadingStopped = true
        let gate = pendingFailureGate; pendingFailureGate = nil
        lifecycleLock.unlock()
        gate?.cancel()
    }
}

enum ModelDownloadProtocolFixture {
    struct Plan {
        let status: Int
        let headers: [String: String]
        let chunks: [Data]
        var errorAfterChunks: Error? = nil
        var hangAfterChunks = false
        var failureGate: ModelDownloadFailureGate? = nil
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var plans: [Plan] = []
    nonisolated(unsafe) private static var recordedRequests: [URLRequest] = []

    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }; return recordedRequests
    }
    static func reset() { lock.lock(); defer { lock.unlock() }; plans = []; recordedRequests = [] }
    static func enqueue(_ plan: Plan) { lock.lock(); defer { lock.unlock() }; plans.append(plan) }
    static func next(for request: URLRequest) throws -> Plan {
        lock.lock(); defer { lock.unlock() }
        recordedRequests.append(request)
        guard !plans.isEmpty else { throw ModelDownloadFailure.rejectedResponse }
        return plans.removeFirst()
    }
}

/// One request's test-only failure release. No callback runs while its lock is
/// held. Cancellation retires a still-pending callback, not one already extracted
/// for invocation. The owning test must also cancel and drain its URLSession task
/// before deleting that task's fixture root.
final class ModelDownloadFailureGate: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    private var released = false
    private var cancelled = false
    private var pending: (@Sendable () -> Void)?

    func arm(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
        guard !armed, !cancelled else { lock.unlock(); return }
        armed = true
        if released { lock.unlock(); action(); return }
        pending = action
        lock.unlock()
    }
    func release() {
        lock.lock()
        guard !released, !cancelled else { lock.unlock(); return }
        released = true
        let action = pending; pending = nil
        lock.unlock()
        action?()
    }
    func cancel() {
        lock.lock(); cancelled = true; pending = nil; lock.unlock()
    }
}
