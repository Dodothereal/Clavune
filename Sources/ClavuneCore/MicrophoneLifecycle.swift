import Foundation

/// A terminal dictation state does not acknowledge closure of microphone hardware.
public struct MicrophoneLifecycle: Sendable {
    public enum State: Sendable { case closed, starting, recording, closing }
    public private(set) var state: State = .closed
    public private(set) var session: UUID?
    public init() {}
    public mutating func requestStart(_ id: UUID) {
        guard state == .closed else { return }
        session = id; state = .starting
    }
    public mutating func firstSample(_ id: UUID) {
        guard session == id, state == .starting else { return }
        state = .recording
    }
    public mutating func requestClose(_ id: UUID?) {
        guard session == id, state != .closed else { return }
        state = .closing
    }
    public mutating func acknowledgeClosed(_ id: UUID?) {
        guard session == id else { return }
        session = nil; state = .closed
    }
}
