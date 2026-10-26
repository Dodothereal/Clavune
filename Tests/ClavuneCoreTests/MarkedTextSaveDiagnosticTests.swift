import AppKit
import SwiftUI
import XCTest
@testable import ClavuneApp
@testable import ClavuneCore

/// One-shot diagnostic, not an acceptance test or a permanent regression claim.
/// Uses the real editor/delegate and coordinator, with only resource boundaries faked.
final class MarkedTextSaveDiagnosticTests: UIFixtureAssertions {
    private enum FixtureFailure: Error {
        case layoutTurnNotSettled, unexpectedStatisticsLoad, writerGateTimedOut
    }

    @MainActor private func editor(in view: NSView) -> PlainTranscriptTextView? {
        if let editor = view as? PlainTranscriptTextView, editor.isEditable { return editor }
        for child in view.subviews {
            if let editor = editor(in: child) { return editor }
        }
        return nil
    }

    @MainActor private func refresh(_ view: NSView) async throws {
        view.layoutSubtreeIfNeeded()
        let settled = expectation(description: "owned marked-text diagnostic layout turn")
        DispatchQueue.main.async { settled.fulfill() }
        guard await XCTWaiter.fulfillment(of: [settled], timeout: 2) == .completed else {
            XCTFail("An unsettled host is invalid diagnostic evidence")
            throw FixtureFailure.layoutTurnNotSettled
        }
        view.layoutSubtreeIfNeeded()
    }

    private func report(_ values: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
        print("CLAVUNE_IME_SAVE_DIAGNOSTIC " + String(decoding: data, as: UTF8.self))
    }

    @MainActor func testSaveDoesNotEraseGenuineUnpublishedMarkedTextIfReachable() async throws {
        guard ProcessInfo.processInfo.environment["CLAVUNE_RUN_UI_HOST_FIXTURES"] == "1",
              ProcessInfo.processInfo.environment["CLAVUNE_RUN_IME_SAVE_DIAGNOSTIC"] == "1" else {
            XCTFail("Requires the separately authorized one-shot offscreen diagnostic flags")
            return
        }
        _ = NSApplication.shared
        let keyBefore = NSApp.keyWindow, mainBefore = NSApp.mainWindow
        let configuration = try AppLaunchConfiguration.parse(environment: [
            "CLAVUNE_QA_PROFILE": "ime-save-" + String(UUID().uuidString.prefix(8)),
            "CLAVUNE_QA_FUNCTIONAL": "synthetic-v1",
        ])
        let original = "Synthetic saved review."
        let composition = " composition"
        let expected = original + composition
        let selected = URL(fileURLWithPath: "/synthetic-ime-save-never-opened.txt")
        let chosen = FixtureValue(0), writes = FixtureValue<[String]>([])
        let statisticsLoads = FixtureValue(0), writerTimedOut = FixtureValue(false)
        // Not registered with XCTestCase: the valid no-Save branch never waits.
        let entered = XCTestExpectation(description: "synthetic writer entered")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let fixture = try CoordinatorFixture(launchConfiguration: configuration,
            processUsageSnapshot: { nil }, configureEnvironment: { environment in
                environment.chooseTranscriptToOpen = { _ in selected }
                environment.readTranscript = { _ in original }
                environment.chooseTranscriptToSave = { _ in
                    chosen.update { $0 += 1 }
                    return selected
                }
                environment.writeTranscript = { text, _ in
                    writes.update { $0.append(text) }
                    entered.fulfill()
                    guard gate.wait(timeout: .now() + 5) == .success else {
                        writerTimedOut.value = true
                        throw FixtureFailure.writerGateTimedOut
                    }
                }
            })
        fixture.coordinator.openTranscript()
        await waitForOperation(fixture)
        XCTAssertEqual(Data(fixture.coordinator.editedText.utf8), Data(original.utf8))
        XCTAssertFalse(fixture.coordinator.hasUnsavedReview)
        let reviewID = fixture.coordinator.session.id
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 580),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer {
            XCTAssertFalse(window.isVisible)
            XCTAssertFalse(window.isKeyWindow)
            XCTAssertFalse(window.isMainWindow)
            XCTAssertTrue(NSApp.keyWindow === keyBefore)
            XCTAssertTrue(NSApp.mainWindow === mainBefore)
            XCTAssertEqual(statisticsLoads.value, 0)
            XCTAssertFalse(writerTimedOut.value)
            XCTAssertEqual(fixture.coordinator.microphone.state, .closed)
            XCTAssertFalse(fixture.coordinator.operationPending)
            XCTAssertFalse(fixture.coordinator.closePending)
            XCTAssertEqual(fixture.resources.counts.value.constructed, 0)
            XCTAssertEqual(fixture.resources.counts.value.opened, 0)
            XCTAssertEqual(fixture.inference.counts.value.loads, 0)
            XCTAssertEqual(fixture.inference.counts.value.decodes, 0)
            XCTAssertEqual(fixture.inference.counts.value.unloads, 0)
            XCTAssertEqual(fixture.permissionCalls, 0)
            XCTAssertEqual(fixture.pickerCalls, 0)
            XCTAssertEqual(fixture.terminationCalls, 0)
            XCTAssertTrue(fixture.hotkeyRegistrar.shortcuts.isEmpty)
            XCTAssertTrue(fixture.clipboard.calls.isEmpty)
            window.close()
            XCTAssertTrue(NSApp.keyWindow === keyBefore)
            XCTAssertTrue(NSApp.mainWindow === mainBefore)
        }
        let host = NSHostingView(rootView: DictationView(coordinator: fixture.coordinator,
            statisticsLoader: { _ in
                statisticsLoads.update { $0 += 1 }
                throw FixtureFailure.unexpectedStatisticsLoad
            }))
        window.contentView = host
        try await refresh(host)
        let editor = try XCTUnwrap(editor(in: host))
        XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertTrue(window.firstResponder === editor)
        editor.setMarkedText(composition,
            selectedRange: NSRange(location: (composition as NSString).length, length: 0),
            replacementRange: NSRange(location: (editor.string as NSString).length, length: 0))
        guard editor.hasMarkedText(), Data(editor.string.utf8) == Data(expected.utf8) else {
            XCTFail("Real setMarkedText did not establish the expected native composition")
            return
        }
        // Do not fabricate a stale binding, suppress a delegate, or send manual
        // text-change notifications. A runtime that publishes immediately ends
        // this hypothesis, without executing Save or counting it as coverage.
        guard Data(editor.string.utf8) != Data(fixture.coordinator.editedText.utf8) else {
            try report(["status": "precondition_not_established_binding_already_current",
                        "native": editor.string, "bound": fixture.coordinator.editedText,
                        "marked": editor.hasMarkedText(), "saveInvoked": false])
            XCTAssertEqual(chosen.value, 0)
            XCTAssertTrue(writes.value.isEmpty)
            return
        }
        guard Data(fixture.coordinator.editedText.utf8) == Data(original.utf8) else {
            XCTFail("Unexpected third binding value is not the proposed stale-snapshot precondition")
            return
        }
        try report(["status": "divergent_composition_observed",
                    "native": editor.string, "bound": fixture.coordinator.editedText,
                    "marked": editor.hasMarkedText()])

        // This is a direct real coordinator command, not a simulated mouse/key
        // event or proof about production NSSavePanel focus/commit behavior.
        fixture.coordinator.saveTranscript()
        guard await XCTWaiter.fulfillment(of: [entered], timeout: 2) == .completed else {
            gate.signal()
            await waitForOperation(fixture)
            XCTFail("The synthetic writer did not enter; no Save observation established")
            return
        }
        do {
            try await refresh(host)
        } catch {
            gate.signal()
            await waitForOperation(fixture)
            throw error
        }
        let heldNative = editor.string
        let heldBound = fixture.coordinator.editedText
        let heldMarked = editor.hasMarkedText()
        let heldPending = fixture.coordinator.transcriptFilePending
        let heldEditable = editor.isEditable
        let heldFirstResponder = window.firstResponder === editor
        gate.signal()
        await waitForOperation(fixture)
        try await refresh(host)
        let after = try XCTUnwrap(self.editor(in: host))
        let afterBound = fixture.coordinator.editedText
        let afterDirty = fixture.coordinator.hasUnsavedReview
        try report(["status": "save_observed",
                    "heldNative": heldNative, "heldBound": heldBound,
                    "heldMarked": heldMarked, "heldPending": heldPending,
                    "heldEditable": heldEditable, "heldFirstResponder": heldFirstResponder,
                    "afterNative": after.string, "afterBound": fixture.coordinator.editedText,
                    "afterMarked": after.hasMarkedText(), "written": writes.value,
                    "afterDirty": fixture.coordinator.hasUnsavedReview])
        XCTAssertTrue(heldPending, "The observation must occur during the real file admission")
        XCTAssertEqual(chosen.value, 1)
        XCTAssertEqual(writes.value.count, 1)
        XCTAssertEqual(fixture.coordinator.session.id, reviewID)
        XCTAssertTrue(after === editor)
        XCTAssertEqual(Data(heldNative.utf8), Data(expected.utf8),
                       "Save must retain genuine pending native composition")
        XCTAssertEqual(Data(heldBound.utf8), Data(expected.utf8),
                       "Composition must publish to the binding before file admission")
        XCTAssertFalse(heldMarked, "The Save boundary must commit, not leave, marked text")
        XCTAssertEqual(Data(after.string.utf8), Data(expected.utf8),
                       "Successful Save must retain the full native draft")
        XCTAssertEqual(Data(afterBound.utf8), Data(expected.utf8),
                       "Successful Save must retain the full bound draft")
        XCTAssertEqual(writes.value.map { Data($0.utf8) }, [Data(expected.utf8)],
                       "The writer must receive exactly the committed UTF-8 payload once")
        XCTAssertFalse(after.hasMarkedText())
        XCTAssertFalse(afterDirty, "A successful exact-payload Save leaves the review clean")
        XCTAssertFalse(fixture.coordinator.hasUnsavedReview)
    }
}
