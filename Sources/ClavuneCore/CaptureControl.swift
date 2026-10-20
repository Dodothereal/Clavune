import AVFAudio
import Foundation

/// Created synchronously in the user's stop handler. Delivery must never resample its clock.
public struct CaptureStopRequest: Equatable, Sendable {
    public let session: UUID
    public let cutoffHostTime: UInt64
    public var cutoffSeconds: Double { AVAudioTime.seconds(forHostTime: cutoffHostTime) }
    public init(session: UUID, cutoffHostTime: UInt64) {
        self.session = session; self.cutoffHostTime = cutoffHostTime
    }
}

public protocol CaptureStopping: Sendable {
    func stop(_ request: CaptureStopRequest) async throws -> CapturedAudio
}

/// Used only by control/UI paths, never by the realtime callback.
/// Permission and privacy are rechecked around the synchronous hardware-start call.
public final class CaptureStartupGate: @unchecked Sendable {
    private let lock = NSLock()
    private var invalidated = false
    public init() {}
    public func invalidate() {
        lock.lock(); invalidated = true; lock.unlock()
    }
    public func check(privacyAllowsCapture: () -> Bool) throws {
        lock.lock(); let current = !invalidated; lock.unlock()
        guard current else { throw DictationError.cancelled }
        guard privacyAllowsCapture() else { throw DictationError.privacyBlocked }
        lock.lock(); let stillCurrent = !invalidated; lock.unlock()
        guard stillCurrent else { throw DictationError.cancelled }
    }
    public func start(privacyAllowsCapture: () -> Bool, open: () throws -> Void,
                      close: () -> Void) throws {
        try check(privacyAllowsCapture: privacyAllowsCapture)
        do {
            try open()
            // An in-flight OS start cannot be atomically combined with TCC/Secure Input.
            // A revoked/cancelled request closes immediately and is never accepted as started.
            try check(privacyAllowsCapture: privacyAllowsCapture)
        } catch {
            close()
            throw error
        }
    }
}

/// Admission remains held even while a nested modal loop dispatches other app events.
public struct OperationAdmission: Sendable {
    public private(set) var token: UUID?
    private var invalidated = false
    public var isHeld: Bool { token != nil }
    public init() {}
    public mutating func begin() -> UUID? {
        guard token == nil else { return nil }
        let next = UUID(); token = next; invalidated = false
        return next
    }
    public mutating func invalidate() { invalidated = true }
    public func permits(_ candidate: UUID) -> Bool { token == candidate && !invalidated }
    public mutating func finish(_ candidate: UUID) {
        guard token == candidate else { return }
        token = nil; invalidated = false
    }
}
