import Foundation
import XCTest
@testable import ClavuneApp
@testable import ClavuneCore

final class HotkeyCommandTests: UIFixtureAssertions {
    @MainActor func testThrowingRegistrarKeepsErrorUntilExplicitRetry() async throws {
        let fixture = try CoordinatorFixture()
        fixture.coordinator.holdToTalk = false
        fixture.coordinator.selectDevelopmentShortcut(.commandShiftSpace)
        fixture.hotkeyRegistrar.failuresRemaining = 1
        fixture.coordinator.setHotkeyEnabled(true)
        XCTAssertFalse(fixture.coordinator.hotkeyEnabled)
        XCTAssertEqual(fixture.hotkeyRegistrar.shortcuts, [.commandShiftSpace])
        XCTAssertEqual(fixture.hotkeyRegistrar.activeCount, 0)
        XCTAssertTrue(fixture.hotkeyRegistrar.registrations.isEmpty)
        let failure = "Hotkey-Konflikt oder Registrierung fehlgeschlagen"
        XCTAssertEqual(fixture.coordinator.hotkeyStatus, failure)
        // A mirrored false update is not a new command and must not erase failure text.
        fixture.coordinator.setHotkeyEnabled(false)
        let laterTurn = expectation(description: "main queue processed a later UI turn")
        DispatchQueue.main.async { laterTurn.fulfill() }
        await fulfillment(of: [laterTurn], timeout: 2)
        XCTAssertEqual(fixture.coordinator.hotkeyStatus, failure)
        XCTAssertFalse(fixture.coordinator.holdToTalk)
        XCTAssertEqual(fixture.coordinator.developmentShortcut, .commandShiftSpace)
        fixture.coordinator.setHotkeyEnabled(true)
        XCTAssertTrue(fixture.coordinator.hotkeyEnabled)
        XCTAssertEqual(fixture.hotkeyRegistrar.shortcuts, [.commandShiftSpace, .commandShiftSpace])
        XCTAssertEqual(fixture.hotkeyRegistrar.activeCount, 1)
        fixture.coordinator.setHotkeyEnabled(false)
        XCTAssertEqual(fixture.hotkeyRegistrar.activeCount, 0)
    }

    @MainActor func testBusyCommandIsIgnoredThroughLoadPreparingRecordingStoppingAndDecode() async throws {
        let fixture = try CoordinatorFixture()
        fixture.coordinator.setHotkeyEnabled(true)
        fixture.resources.automaticallyDeliverFirstSample = false
        let loaded = expectation(description: "fake load entered")
        let load = ControlledDelivery()
        fixture.inference.onLoad = loaded; fixture.inference.loadGate = load
        fixture.coordinator.start()
        await fulfillment(of: [loaded], timeout: 2)
        await load.waitUntilSuspended()
        assertHotkeyEnableIgnored(fixture)
        await load.release()
        await waitForOperation(fixture)
        XCTAssertEqual(fixture.coordinator.session.phase, .preparing)
        assertHotkeyEnableIgnored(fixture)
        let id = try XCTUnwrap(fixture.coordinator.session.id)
        let recording = expectation(description: "first sample accepted")
        fixture.observePhase(.recording, expectation: recording)
        fixture.resources.firstSample(session: id)
        await fulfillment(of: [recording], timeout: 2)
        assertHotkeyEnableIgnored(fixture)
        let stopped = expectation(description: "stop delivery held")
        fixture.queue.pause(nextSubmission: stopped)
        let decoding = expectation(description: "fake decode entered")
        let decode = ControlledDelivery()
        fixture.inference.onDecode = decoding; fixture.inference.decodeGate = decode
        fixture.coordinator.stop()
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertEqual(fixture.coordinator.session.phase, .stopping)
        assertHotkeyEnableIgnored(fixture)
        fixture.queue.resume()
        await fulfillment(of: [decoding], timeout: 2)
        await decode.waitUntilSuspended()
        XCTAssertEqual(fixture.coordinator.session.phase, .transcribing)
        XCTAssertEqual(fixture.coordinator.microphone.state, .closed)
        assertHotkeyEnableIgnored(fixture)
        fixture.coordinator.cancel()
        assertHotkeyEnableIgnored(fixture)
        await decode.release()
        await cancelAndDrain(fixture)
        fixture.coordinator.setHotkeyEnabled(false)
        XCTAssertEqual(fixture.hotkeyRegistrar.activeCount, 0)
    }

    @MainActor func testBusyCommandIsIgnoredDuringPermissionAndCaptureCloseDrain() async throws {
        let permissionFixture = try CoordinatorFixture()
        permissionFixture.permissionStatus = .notDetermined
        let requested = expectation(description: "permission response pending")
        permissionFixture.permission.requested = requested
        permissionFixture.coordinator.start()
        await fulfillment(of: [requested], timeout: 2)
        assertHotkeyEnableIgnored(permissionFixture)
        permissionFixture.coordinator.cancel()
        permissionFixture.permission.resolve(false)
        await cancelAndDrain(permissionFixture)

        let captureFixture = try CoordinatorFixture()
        await startRecording(captureFixture)
        let submitted = expectation(description: "capture close queued")
        captureFixture.queue.pause(nextSubmission: submitted)
        captureFixture.coordinator.cancel()
        await fulfillment(of: [submitted], timeout: 2)
        XCTAssertTrue(captureFixture.coordinator.closePending)
        XCTAssertEqual(captureFixture.coordinator.microphone.state, .closing)
        assertHotkeyEnableIgnored(captureFixture)
        captureFixture.queue.resume()
        await cancelAndDrain(captureFixture)
    }

    @MainActor func testBusyCommandIsIgnoredDuringImportPickerAdmissionAndUnload() async throws {
        let fixture = try CoordinatorFixture()
        var pickerChecked = false
        fixture.chooseModel = { [unowned fixture] in
            XCTAssertTrue(fixture.coordinator.busy)
            self.assertHotkeyEnableIgnored(fixture)
            pickerChecked = true
            return nil // Never enter filesystem import or display a real picker.
        }
        fixture.coordinator.importModel()
        XCTAssertTrue(pickerChecked)
        XCTAssertEqual(fixture.pickerCalls, 1)
        XCTAssertFalse(fixture.coordinator.busy)
        let unloading = expectation(description: "fake unload pending")
        let gate = ControlledDelivery()
        fixture.inference.onUnload = unloading; fixture.inference.unloadGate = gate
        fixture.coordinator.unload()
        await fulfillment(of: [unloading], timeout: 2)
        await gate.waitUntilSuspended()
        assertHotkeyEnableIgnored(fixture)
        await gate.release()
        await waitForOperation(fixture)
    }

    @MainActor func testRetainedFakeRegistrationRoutesHoldAndToggleEdges() async throws {
        let fixture = try CoordinatorFixture()
        fixture.coordinator.setHotkeyEnabled(true)
        let registration = try XCTUnwrap(fixture.hotkeyRegistrar.registrations.first)
        let recording = expectation(description: "hold down started production coordinator")
        fixture.observePhase(.recording, expectation: recording)
        registration.send(down: true)
        await fulfillment(of: [recording], timeout: 2)
        await waitForOperation(fixture)
        let reviewed = expectation(description: "hold up stopped production coordinator")
        fixture.observePhase(.review, expectation: reviewed)
        registration.send(down: false)
        await fulfillment(of: [reviewed], timeout: 2)
        await waitForOperation(fixture)
        fixture.coordinator.discard()
        fixture.coordinator.holdToTalk = false
        let toggled = expectation(description: "toggle down started production coordinator")
        fixture.observePhase(.recording, expectation: toggled)
        registration.send(down: true)
        await fulfillment(of: [toggled], timeout: 2)
        await waitForOperation(fixture)
        registration.send(down: false)
        XCTAssertEqual(fixture.coordinator.session.phase, .recording)
        let final = expectation(description: "second toggle down stopped recording")
        fixture.observePhase(.review, expectation: final)
        registration.send(down: true)
        await fulfillment(of: [final], timeout: 2)
        await waitForOperation(fixture)
        XCTAssertEqual(fixture.hotkeyRegistrar.shortcuts.count, 1)
        XCTAssertEqual(fixture.inference.counts.value.decodes, 2)
        fixture.coordinator.setHotkeyEnabled(false)
    }

    @MainActor func testFakeHotkeySecureInputRevalidationCancelsWithoutDecode() async throws {
        let fixture = try CoordinatorFixture()
        fixture.coordinator.setHotkeyEnabled(true)
        let registration = try XCTUnwrap(fixture.hotkeyRegistrar.registrations.first)
        await startRecording(fixture)
        fixture.privacy.value = false
        registration.send(down: false)
        XCTAssertEqual(fixture.coordinator.session.phase, .cancelled)
        await cancelAndDrain(fixture)
        XCTAssertEqual(fixture.inference.counts.value.decodes, 0)
        XCTAssertEqual(fixture.resources.counts.value.closed, 1)
        fixture.coordinator.setHotkeyEnabled(false)
    }
}
