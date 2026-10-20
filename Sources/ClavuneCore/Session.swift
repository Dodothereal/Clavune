import Foundation

public enum SessionPhase: String, Sendable {
    case idle, preparing, recording, stopping, transcribing, review, cancelled, failed
    public var isBusy: Bool { [.preparing, .recording, .stopping, .transcribing].contains(self) }
}

public struct SessionMachine: Sendable {
    public private(set) var id: UUID?
    public private(set) var phase: SessionPhase = .idle
    public private(set) var rawTranscript = ""
    public private(set) var failure: DictationError?
    public init() {}
    @discardableResult public mutating func begin() throws -> UUID {
        guard !phase.isBusy else { throw DictationError.busy }
        let next = UUID()
        id = next; phase = .preparing; failure = nil; rawTranscript = ""
        return next
    }
    public mutating func recording(_ session: UUID) {
        guard id == session, phase == .preparing else { return }
        phase = .recording
    }
    @discardableResult public mutating func stopping(_ session: UUID) -> Bool {
        guard id == session, phase == .recording else { return false }
        phase = .stopping; return true
    }
    public mutating func transcribing(_ session: UUID) {
        guard id == session, phase == .stopping else { return }
        phase = .transcribing
    }
    public mutating func result(_ text: String, session: UUID) {
        guard id == session, phase == .transcribing else { return }
        rawTranscript = text; phase = .review
    }
    public mutating func fail(_ error: DictationError, session: UUID) {
        guard id == session, phase.isBusy else { return }
        failure = error; phase = error == .cancelled ? .cancelled : .failed
    }
    public mutating func cancel() {
        id = nil; rawTranscript = ""; failure = nil; phase = .cancelled
    }
    public mutating func discard() {
        id = nil; rawTranscript = ""; failure = nil; phase = .idle
    }
}

public struct SessionMetrics: Sendable {
    public let session: UUID
    public var requestedStart: UInt64
    public var firstSample: UInt64?
    public var requestedStop: UInt64?
    public var captureClosed: UInt64?
    public var finalText: UInt64?
    public var insertionDispatched: UInt64?
    public var insertionVerified: UInt64?
    public var sourceSampleRate: Double?
    public var frames16k = 0
    public var modelWarm = false
    public var modelLoadSeconds: Double?
    public var decodeSeconds: Double?
    public init(session: UUID, requestedStart: UInt64) {
        self.session = session; self.requestedStart = requestedStart
    }
    // No text, paths, clipboard or audio content belongs in this structure.
}
