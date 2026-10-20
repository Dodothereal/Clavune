import XCTest
@testable import ClavuneCore

final class CaptureControlTests: XCTestCase {
    func testCancelledBeforeDelayedStartCannotOpenCapture() async {
        let authorization = CaptureStartupGate(), delivery = ControlledDelivery()
        let operation = Task {
            await delivery.suspend()
            var opened = false
            do {
                try authorization.start(privacyAllowsCapture: { true }, open: { opened = true }, close: {})
                return (opened, nil as DictationError?)
            } catch { return (opened, error as? DictationError) }
        }
        await delivery.waitUntilSuspended()
        authorization.invalidate() // cancel arrives before the delayed start enqueue.
        await delivery.release()
        let result = await operation.value
        XCTAssertFalse(result.0)
        XCTAssertEqual(result.1, .cancelled)
    }
    func testChangedPrivacyDuringPreparationPreventsOpen() throws {
        let authorization = CaptureStartupGate()
        try authorization.check { true } // earlier preflight before permission/model work.
        var opened = false
        XCTAssertThrowsError(try authorization.start(privacyAllowsCapture: { false },
                                                     open: { opened = true }, close: {})) {
            XCTAssertEqual($0 as? DictationError, .privacyBlocked)
        }
        XCTAssertFalse(opened)
    }
    func testRevokedDuringSynchronousStartClosesBeforeSuccess() {
        let authorization = CaptureStartupGate()
        var permitted = true, hardwareOpen = false, closed = 0
        XCTAssertThrowsError(try authorization.start(privacyAllowsCapture: { permitted }, open: {
            hardwareOpen = true; permitted = false
        }, close: {
            hardwareOpen = false; closed += 1
        })) {
            XCTAssertEqual($0 as? DictationError, .privacyBlocked)
        }
        XCTAssertFalse(hardwareOpen)
        XCTAssertEqual(closed, 1)
    }
    func testCancellationDuringPrivacyProbeNeverCallsOpen() {
        let authorization = CaptureStartupGate()
        var opened = false
        XCTAssertThrowsError(try authorization.start(privacyAllowsCapture: {
            authorization.invalidate(); return true
        }, open: { opened = true }, close: {})) {
            XCTAssertEqual($0 as? DictationError, .cancelled)
        }
        XCTAssertFalse(opened)
    }
    func testThrowingCancellationFactoryDoesNotAdmitOrEraseReview() throws {
        enum AllocationFailure: Error { case injected }
        var session = SessionMachine()
        let oldID = try session.begin()
        session.recording(oldID); session.stopping(oldID); session.transcribing(oldID)
        session.result("review retained", session: oldID)
        XCTAssertThrowsError(try session.begin(preparing: { () throws -> Int in throw AllocationFailure.injected })) {
            XCTAssertTrue($0 is AllocationFailure)
        }
        XCTAssertEqual(session.phase, .review)
        XCTAssertEqual(session.id, oldID)
        XCTAssertEqual(session.rawTranscript, "review retained")
        let admitted = try session.begin(preparing: { 7 })
        XCTAssertEqual(admitted.resource, 7)
        XCTAssertEqual(session.phase, .preparing)
    }
    func testFailureBeforeStartCompletionCannotReportRecording() throws {
        var session = SessionMachine()
        let id = try session.begin()
        session.fail(.audioUnavailable, session: id)
        XCTAssertEqual(session.id, id) // ID alone is insufficient to admit late completion.
        XCTAssertFalse(session.recording(id))
        XCTAssertEqual(session.phase, .failed)
        XCTAssertEqual(session.failure, .audioUnavailable)
    }
    func testModalAdmissionStaysHeldAcrossCancelUntilPickerReturns() throws {
        var admission = OperationAdmission()
        let token = try XCTUnwrap(admission.begin())
        XCTAssertTrue(admission.isHeld) // hotkey admission remains blocked in the nested modal loop.
        XCTAssertNil(admission.begin())
        admission.invalidate()
        XCTAssertFalse(admission.permits(token))
        XCTAssertTrue(admission.isHeld)
        admission.finish(UUID()) // a stale completion cannot release this operation.
        XCTAssertTrue(admission.isHeld)
        admission.finish(token)
        XCTAssertFalse(admission.isHeld)
        XCTAssertNotNil(admission.begin())
    }
    func testSlowCloseRetainsMicrophoneIndicatorAfterSessionCancel() async throws {
        var session = SessionMachine(), microphone = MicrophoneLifecycle()
        let id = try session.begin()
        microphone.requestStart(id); microphone.firstSample(id); session.recording(id)
        let close = ControlledDelivery()
        let operation = Task { await close.suspend() }
        await close.waitUntilSuspended()
        microphone.requestClose(id); session.cancel()
        XCTAssertEqual(session.phase, .cancelled)
        XCTAssertEqual(microphone.state, .closing)
        microphone.acknowledgeClosed(UUID())
        XCTAssertEqual(microphone.state, .closing)
        await close.release(); await operation.value
        microphone.acknowledgeClosed(id)
        XCTAssertEqual(microphone.state, .closed)
    }
    func testCancelClearsRawTranscriptAfterUserEmptiesEditedText() throws {
        var session = SessionMachine()
        let id = try session.begin()
        session.recording(id); session.stopping(id); session.transcribing(id)
        session.result("private raw transcript", session: id)
        let editedText = "" // review was manually emptied; raw text still exists.
        XCTAssertTrue(editedText.isEmpty)
        XCTAssertFalse(session.rawTranscript.isEmpty)
        session.cancel()
        XCTAssertTrue(session.rawTranscript.isEmpty)
        XCTAssertNil(session.id)
    }
}

/// Deterministic interleaving; no sleeps, microphone or real permission changes.
actor ControlledDelivery {
    private var suspended = false
    private var entered: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    func suspend() async {
        suspended = true; entered?.resume(); entered = nil
        await withCheckedContinuation { releaseContinuation = $0 }
    }
    func waitUntilSuspended() async {
        if suspended { return }
        await withCheckedContinuation { entered = $0 }
    }
    func release() { releaseContinuation?.resume(); releaseContinuation = nil }
}
