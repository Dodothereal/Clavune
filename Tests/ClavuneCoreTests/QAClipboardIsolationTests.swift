import AppKit
import Combine
import SwiftUI
import XCTest
@testable import ClavuneApp
@testable import ClavuneCore

/// Opt-in offscreen bridge check. It does not inspect or alter the general pasteboard.
final class QAClipboardIsolationTests: XCTestCase {
    @MainActor private func editors(in view: NSView) -> [PlainTranscriptTextView] {
        let current = (view as? PlainTranscriptTextView).map { [$0] } ?? []
        return current + view.subviews.flatMap { editors(in: $0) }
    }

    @MainActor private func waitForImport(_ coordinator: AppCoordinator) async -> Bool {
        guard coordinator.operationPending else { return true }
        let done = expectation(description: "synthetic import drained")
        let observation = coordinator.$operationPending.filter { !$0 }.prefix(1).sink { _ in done.fulfill() }
        let outcome = await XCTWaiter.fulfillment(of: [done], timeout: 3)
        XCTAssertEqual(outcome, .completed)
        observation.cancel()
        return outcome == .completed
    }

    @MainActor func testMountedFunctionalQAEditorRoutesNativeSelectionCopyAndCutInMemory() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CLAVUNE_RUN_UI_HOST_FIXTURES"] == "1",
                          "Run only in the authorized macOS in-memory UI-host fixture pass")
        _ = NSApplication.shared
        let configuration = try AppLaunchConfiguration.parse(environment: [
            "CLAVUNE_QA_PROFILE": "copy-" + String(UUID().uuidString.prefix(12)),
            "CLAVUNE_QA_FUNCTIONAL": "synthetic-v1"])
        let context = try FunctionalQAContext(configuration: configuration)
        let coordinator = AppCoordinator(policy: try ResourcePolicy.bundled(), capture: context.capture,
            inference: context.inference, environment: context.environment(terminate: {}),
            launchConfiguration: configuration, modelSelection: context.modelSelection)
        // Retain synthetic owned files if a timed-out operation may still be
        // reading them; ordinary completion cleans them at test end.
        defer { if !coordinator.operationPending { try? context.cleanup() } }
        coordinator.importAudio()
        guard await waitForImport(coordinator) else { return }
        XCTAssertEqual(coordinator.session.phase, .review)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 820),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: DictationView(coordinator: coordinator))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let updated = expectation(description: "native host update turn")
        DispatchQueue.main.async { updated.fulfill() }
        await fulfillment(of: [updated], timeout: 2)
        host.layoutSubtreeIfNeeded()

        let editor = try XCTUnwrap(editors(in: host).first(where: \.isEditable), "Editable review not mounted")
        // Never dispatch native Copy/Cut if injection regresses: that would access
        // the real general pasteboard in this test process.
        guard editor.clipboardWriteSink is QATranscriptClipboardSink else {
            XCTFail("Functional QA editor has no guarded clipboard boundary")
            return
        }
        XCTAssertFalse(editor.allowsSystemPasteboardRead)
        let original = FunctionalQAContext.transcript
        let selected = "quiet morning"
        let auxiliarySelected = "clear sentence"
        enum SelectionFailure: Error { case unsafeBoundary, unexpectedText, invalidRange }
        // Fail before native Copy/Cut if fixture copy changes or injection regresses.
        // NSString ranges and NSTextView selections both use UTF-16 offsets.
        @MainActor func selectFixtureText(_ needle: String, in target: PlainTranscriptTextView,
                               expectedText: String) throws -> NSRange {
            guard target.clipboardWriteSink is QATranscriptClipboardSink,
                  !target.allowsSystemPasteboardRead else {
                XCTFail("Native clipboard action requires the guarded in-memory boundary")
                throw SelectionFailure.unsafeBoundary
            }
            XCTAssertEqual(target.string, expectedText)
            guard target.string == expectedText else { throw SelectionFailure.unexpectedText }
            let text = target.string as NSString
            let range = text.range(of: needle)
            XCTAssertNotEqual(range.location, NSNotFound, "Fixture selection must exist")
            XCTAssertGreaterThan(range.length, 0, "Copy/Cut must exercise a nonempty selection")
            XCTAssertEqual(range.length, needle.utf16.count)
            guard range.location != NSNotFound, range.length > 0,
                  range.length == needle.utf16.count,
                  range.location <= text.length, range.length <= text.length - range.location else {
                throw SelectionFailure.invalidRange
            }
            target.setSelectedRange(range)
            XCTAssertEqual(target.selectedRange(), range)
            guard target.selectedRange() == range else { throw SelectionFailure.invalidRange }
            return range
        }
        _ = try selectFixtureText(selected, in: editor, expectedText: original)
        editor.copy(nil)
        XCTAssertEqual(context.copiedText, selected)
        XCTAssertEqual(editor.string, original)
        XCTAssertEqual(coordinator.editedText, original)

        let auxiliaryWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 820),
                                       styleMask: [.titled], backing: .buffered, defer: true)
        auxiliaryWindow.isReleasedWhenClosed = false
        defer { auxiliaryWindow.close() }
        let auxiliaryHost = NSHostingView(rootView: DictationView(coordinator: coordinator,
                                                                  isAuxiliaryPanel: true))
        auxiliaryWindow.contentView = auxiliaryHost
        auxiliaryHost.layoutSubtreeIfNeeded()
        let auxiliaryUpdated = expectation(description: "auxiliary native host update turn")
        DispatchQueue.main.async { auxiliaryUpdated.fulfill() }
        await fulfillment(of: [auxiliaryUpdated], timeout: 2)
        auxiliaryHost.layoutSubtreeIfNeeded()
        let auxiliaryEditor = try XCTUnwrap(editors(in: auxiliaryHost).first(where: \.isEditable),
                                            "Auxiliary review editor not mounted")
        guard auxiliaryEditor.clipboardWriteSink is QATranscriptClipboardSink else {
            XCTFail("Auxiliary QA editor has no guarded clipboard boundary")
            return
        }
        XCTAssertFalse(auxiliaryEditor.allowsSystemPasteboardRead)
        _ = try selectFixtureText(auxiliarySelected, in: auxiliaryEditor, expectedText: original)
        auxiliaryEditor.copy(nil)
        XCTAssertEqual(context.copiedText, auxiliarySelected,
                       "A distinct selection proves the auxiliary Copy replaced the prior in-memory value")
        XCTAssertEqual(auxiliaryEditor.string, original)
        XCTAssertEqual(coordinator.editedText, original)

        let mainCutRange = try selectFixtureText(selected, in: editor, expectedText: original)
        let afterMainCut = (original as NSString).replacingCharacters(in: mainCutRange, with: "")
        editor.cut(nil)
        XCTAssertEqual(context.copiedText, selected)
        XCTAssertEqual(editor.string, afterMainCut)
        XCTAssertEqual(coordinator.editedText, afterMainCut)
        let mainCutUpdated = expectation(description: "main cut reaches the auxiliary editor")
        DispatchQueue.main.async { mainCutUpdated.fulfill() }
        await fulfillment(of: [mainCutUpdated], timeout: 2)
        auxiliaryHost.layoutSubtreeIfNeeded()

        let auxiliaryCutRange = try selectFixtureText(auxiliarySelected, in: auxiliaryEditor,
                                                      expectedText: afterMainCut)
        let afterBothCuts = (afterMainCut as NSString).replacingCharacters(in: auxiliaryCutRange, with: "")
        auxiliaryEditor.cut(nil)
        XCTAssertEqual(context.copiedText, auxiliarySelected)
        XCTAssertEqual(auxiliaryEditor.string, afterBothCuts)
        XCTAssertEqual(coordinator.editedText, afterBothCuts)
        let auxiliaryCutUpdated = expectation(description: "auxiliary cut reaches the main editor")
        DispatchQueue.main.async { auxiliaryCutUpdated.fulfill() }
        await fulfillment(of: [auxiliaryCutUpdated], timeout: 2)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(editor.string, afterBothCuts)
        XCTAssertTrue(editor.clipboardWriteSink is QATranscriptClipboardSink)
        XCTAssertTrue(auxiliaryEditor.clipboardWriteSink is QATranscriptClipboardSink)
        XCTAssertFalse(editor.allowsSystemPasteboardRead)
        XCTAssertFalse(auxiliaryEditor.allowsSystemPasteboardRead)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(auxiliaryWindow.isVisible)
    }

    @MainActor func testPresentationQASinkRejectsNativeCopyAndCut() throws {
        let configuration = try AppLaunchConfiguration.parse(environment: [
            "CLAVUNE_QA_PROFILE": "copy-" + String(UUID().uuidString.prefix(12))])
        let fixture = try CoordinatorFixture(launchConfiguration: configuration)
        let sink = try XCTUnwrap(fixture.coordinator.qaTranscriptClipboardSink)
        let editor = PlainTranscriptTextView(frame: .zero)
        editor.clipboardWriteSink = sink
        XCTAssertFalse(editor.allowsSystemPasteboardRead)
        XCTAssertTrue(editor.readablePasteboardTypes.isEmpty)
        XCTAssertTrue(editor.acceptableDragTypes.isEmpty)
        XCTAssertNil(editor.validRequestor(forSendType: .string, returnType: .string))
        editor.isEditable = true
        editor.string = "SYNTHETIC QA SELECTION"
        let namedBoard = NSPasteboard.withUniqueName()
        defer { namedBoard.releaseGlobally() }
        namedBoard.setString("SYNTHETIC QA BOARD", forType: .string)
        XCTAssertFalse(editor.readSelection(from: namedBoard))
        XCTAssertFalse(editor.readSelection(from: namedBoard, type: .string))
        XCTAssertEqual(editor.string, "SYNTHETIC QA SELECTION")
        let selected = (editor.string as NSString).range(of: "SYNTHETIC QA")
        editor.setSelectedRange(selected)
        editor.copy(nil)
        editor.cut(nil)
        XCTAssertTrue(fixture.clipboard.calls.isEmpty)
        XCTAssertEqual(editor.string, "SYNTHETIC QA SELECTION")
        XCTAssertEqual(editor.selectedRange(), selected)

        let production = try CoordinatorFixture()
        XCTAssertNil(production.coordinator.qaTranscriptClipboardSink)
        let productionEditor = PlainTranscriptTextView(frame: .zero)
        XCTAssertTrue(productionEditor.allowsSystemPasteboardRead)
        // Production's nil sink intentionally uses AppKit's native clipboard,
        // which this test never invokes.
    }
}
