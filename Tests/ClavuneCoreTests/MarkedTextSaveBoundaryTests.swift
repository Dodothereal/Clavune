import AppKit
import Combine
import SwiftUI
import XCTest
@testable import ClavuneApp
@testable import ClavuneCore

/// Real native composition and real @Published callbacks; only file/resource
/// boundaries are synthetic. Never changes the delegate or fabricates a binding.
final class MarkedTextSaveBoundaryTests: UIFixtureAssertions {
    private enum FixtureFailure: Error { case setup, layout, unexpectedStatistics }
    @MainActor private final class IO {
        let readText: FixtureValue<String>
        let written = FixtureValue<[String]>([])
        var saveAccepted = true
        var openChoosers = 0, saveChoosers = 0, quitConfirmations = 0
        var quitObservedText: [String] = []
        let statisticsLoads = FixtureValue(0)
        weak var coordinator: AppCoordinator?
        init(readText: String = "Synthetic saved review.") {
            self.readText = FixtureValue(readText)
        }
    }
    @MainActor private struct Host {
        let window: NSWindow
        let view: NSHostingView<DictationView>
        let editor: PlainTranscriptTextView
        let keyBefore: NSWindow?
        let mainBefore: NSWindow?
    }

    @MainActor private func refresh(_ view: NSView) async throws {
        view.layoutSubtreeIfNeeded()
        let settled = expectation(description: "owned Save-boundary host update")
        DispatchQueue.main.async { settled.fulfill() }
        guard await XCTWaiter.fulfillment(of: [settled], timeout: 2) == .completed else {
            XCTFail("Unsettled native host is not boundary evidence")
            throw FixtureFailure.layout
        }
        view.layoutSubtreeIfNeeded()
    }
    @MainActor private func editor(in view: NSView) -> PlainTranscriptTextView? {
        if let editor = view as? PlainTranscriptTextView, editor.isEditable { return editor }
        for child in view.subviews {
            if let editor = editor(in: child) { return editor }
        }
        return nil
    }
    @MainActor private func makeFixture(_ io: IO) async throws -> CoordinatorFixture {
        guard ProcessInfo.processInfo.environment["CLAVUNE_RUN_UI_HOST_FIXTURES"] == "1" else {
            XCTFail("Requires the authorized offscreen UI-host fixture pass")
            throw FixtureFailure.setup
        }
        _ = NSApplication.shared
        let configuration = try AppLaunchConfiguration.parse(environment: [
            "CLAVUNE_QA_PROFILE": "save-boundary-" + String(UUID().uuidString.prefix(8)),
            "CLAVUNE_QA_FUNCTIONAL": "synthetic-v1",
        ])
        let selected = URL(fileURLWithPath: "/synthetic-save-boundary-never-opened.txt")
        let readText = io.readText, written = io.written
        let fixture = try CoordinatorFixture(launchConfiguration: configuration,
            processUsageSnapshot: { nil }, configureEnvironment: { environment in
                environment.chooseTranscriptToOpen = { _ in io.openChoosers += 1; return selected }
                environment.readTranscript = { _ in readText.value }
                environment.chooseTranscriptToSave = { _ in
                    io.saveChoosers += 1
                    return io.saveAccepted ? selected : nil
                }
                environment.writeTranscript = { text, _ in written.update { $0.append(text) } }
                environment.confirmTranscriptReplacement = { _ in true }
                environment.confirmUnsavedReviewQuit = { _ in
                    io.quitConfirmations += 1
                    io.quitObservedText.append(io.coordinator?.editedText ?? "missing coordinator")
                    return .cancel
                }
            })
        io.coordinator = fixture.coordinator
        fixture.coordinator.openTranscript()
        await waitForOperation(fixture)
        XCTAssertFalse(fixture.coordinator.hasUnsavedReview)
        return fixture
    }
    @MainActor private func makeHost(_ fixture: CoordinatorFixture, io: IO) async throws -> Host {
        let keyBefore = NSApp.keyWindow, mainBefore = NSApp.mainWindow
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 580),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let loads = io.statisticsLoads
        let view = NSHostingView(rootView: DictationView(coordinator: fixture.coordinator,
            statisticsLoader: { _ in loads.update { $0 += 1 }; throw FixtureFailure.unexpectedStatistics }))
        window.contentView = view
        do {
            try await refresh(view)
            return Host(window: window, view: view, editor: try XCTUnwrap(editor(in: view)),
                        keyBefore: keyBefore, mainBefore: mainBefore)
        } catch { window.close(); throw error }
    }
    @MainActor private func close(_ host: Host, fixture: CoordinatorFixture, io: IO) {
        XCTAssertFalse(host.window.isVisible)
        XCTAssertFalse(host.window.isKeyWindow)
        XCTAssertFalse(host.window.isMainWindow)
        XCTAssertTrue(NSApp.keyWindow === host.keyBefore)
        XCTAssertTrue(NSApp.mainWindow === host.mainBefore)
        XCTAssertFalse(fixture.coordinator.operationPending)
        XCTAssertFalse(fixture.coordinator.closePending)
        XCTAssertFalse(fixture.coordinator.transcriptFilePending)
        XCTAssertEqual(fixture.coordinator.microphone.state, .closed)
        XCTAssertEqual(fixture.resources.counts.value.constructed, 0)
        XCTAssertEqual(fixture.resources.counts.value.opened, 0)
        XCTAssertEqual(fixture.inference.counts.value.loads, 0)
        XCTAssertEqual(fixture.inference.counts.value.decodes, 0)
        XCTAssertEqual(fixture.inference.counts.value.unloads, 0)
        XCTAssertEqual(fixture.permissionCalls, 0)
        XCTAssertEqual(fixture.pickerCalls, 0)
        XCTAssertEqual(fixture.terminationCalls, 0)
        XCTAssertEqual(io.statisticsLoads.value, 0)
        XCTAssertTrue(fixture.hotkeyRegistrar.shortcuts.isEmpty)
        XCTAssertTrue(fixture.clipboard.calls.isEmpty)
        host.window.close()
        XCTAssertTrue(NSApp.keyWindow === host.keyBefore)
        XCTAssertTrue(NSApp.mainWindow === host.mainBefore)
    }
    @MainActor private func compose(_ suffix: String, in host: Host,
                                     fixture: CoordinatorFixture, bound: String) throws -> String {
        guard host.window.makeFirstResponder(host.editor) else {
            XCTFail("Owned editor did not become the hidden window's first responder")
            throw FixtureFailure.setup
        }
        host.editor.setMarkedText(suffix,
            selectedRange: NSRange(location: (suffix as NSString).length, length: 0),
            replacementRange: NSRange(location: (host.editor.string as NSString).length, length: 0))
        let expected = bound + suffix
        guard host.editor.hasMarkedText(),
              Data(host.editor.string.utf8) == Data(expected.utf8),
              Data(fixture.coordinator.editedText.utf8) == Data(bound.utf8),
              Data(host.editor.string.utf8) != Data(fixture.coordinator.editedText.utf8) else {
            XCTFail("Requires the already reproduced genuine unpublished native composition")
            throw FixtureFailure.setup
        }
        return expected
    }

    @MainActor func testChooserCancelRetainsComposedDraftUndoAndSuccessfulRetry() async throws {
        let io = IO(), fixture = try await makeFixture(io)
        let host = try await makeHost(fixture, io: io)
        defer { close(host, fixture: fixture, io: io) }
        let reviewID = fixture.coordinator.session.id
        let undo = try XCTUnwrap(host.editor.undoManager)
        XCTAssertTrue(host.window.makeFirstResponder(host.editor))
        undo.beginUndoGrouping()
        host.editor.insertText(" prior", replacementRange: NSRange(location: (host.editor.string as NSString).length, length: 0))
        undo.endUndoGrouping()
        // Separate the preceding edit into its own AppKit event group so the
        // marked-text composition has an independently observable undo step.
        try await refresh(host.view)
        XCTAssertTrue(undo.canUndo)
        let bound = fixture.coordinator.editedText
        let expected = try compose(" composition", in: host, fixture: fixture, bound: bound)
        io.saveAccepted = false
        fixture.coordinator.saveTranscript()
        try await refresh(host.view)
        XCTAssertEqual(io.saveChoosers, 1)
        XCTAssertTrue(io.written.value.isEmpty)
        XCTAssertEqual(Data(host.editor.string.utf8), Data(expected.utf8))
        XCTAssertEqual(Data(fixture.coordinator.editedText.utf8), Data(expected.utf8))
        XCTAssertTrue(fixture.coordinator.hasUnsavedReview)
        XCTAssertEqual(fixture.coordinator.session.id, reviewID)
        XCTAssertTrue(try XCTUnwrap(editor(in: host.view)) === host.editor)
        XCTAssertTrue(host.editor.undoManager === undo)
        XCTAssertTrue(undo.canUndo)

        // The real marked-text commit must remain one native Undo/Redo history
        // item after the chooser is cancelled, and it must keep publishing the
        // exact bytes back through the coordinator binding.
        undo.undo()
        try await refresh(host.view)
        XCTAssertEqual(Data(host.editor.string.utf8), Data(bound.utf8))
        XCTAssertEqual(Data(fixture.coordinator.editedText.utf8), Data(bound.utf8))
        XCTAssertEqual(host.editor.selectedRange(), NSRange(location: (bound as NSString).length, length: 0))
        XCTAssertTrue(fixture.coordinator.hasUnsavedReview, "Earlier edit remains dirty after composition Undo")
        XCTAssertTrue(host.editor.undoManager === undo)
        XCTAssertTrue(undo.canRedo)
        XCTAssertEqual(io.written.value, [])

        undo.redo()
        try await refresh(host.view)
        XCTAssertEqual(Data(host.editor.string.utf8), Data(expected.utf8))
        XCTAssertEqual(Data(fixture.coordinator.editedText.utf8), Data(expected.utf8))
        XCTAssertEqual(host.editor.selectedRange(), NSRange(location: (expected as NSString).length, length: 0))
        XCTAssertTrue(fixture.coordinator.hasUnsavedReview)
        XCTAssertTrue(host.editor.undoManager === undo)
        XCTAssertTrue(undo.canUndo)
        XCTAssertEqual(io.written.value, [])

        io.saveAccepted = true
        fixture.coordinator.saveTranscript()
        await waitForOperation(fixture)
        try await refresh(host.view)
        XCTAssertEqual(io.saveChoosers, 2)
        XCTAssertEqual(io.written.value.map { Data($0.utf8) }, [Data(expected.utf8)])
        XCTAssertFalse(fixture.coordinator.hasUnsavedReview)
        XCTAssertEqual(Data(host.editor.string.utf8), Data(expected.utf8))
        XCTAssertTrue(host.editor.undoManager === undo)
        XCTAssertTrue(undo.canUndo)
        XCTAssertEqual(io.written.value.map { Data($0.utf8) }, [Data(expected.utf8)],
                       "Undo history must not cause a second write")

        undo.undo()
        try await refresh(host.view)
        XCTAssertEqual(Data(host.editor.string.utf8), Data(bound.utf8))
        XCTAssertEqual(Data(fixture.coordinator.editedText.utf8), Data(bound.utf8))
        XCTAssertTrue(fixture.coordinator.hasUnsavedReview, "Undo after Save makes the review dirty again")
        XCTAssertTrue(undo.canRedo)

        undo.redo()
        try await refresh(host.view)
        XCTAssertEqual(Data(host.editor.string.utf8), Data(expected.utf8))
        XCTAssertEqual(Data(fixture.coordinator.editedText.utf8), Data(expected.utf8))
        XCTAssertFalse(fixture.coordinator.hasUnsavedReview, "Redo returns to the exact saved draft")
        XCTAssertEqual(io.written.value.map { Data($0.utf8) }, [Data(expected.utf8)])
    }

    @MainActor func testMarkedUnicodeSelectionReplacementCommitsExactBytesOnChooserCancel() async throws {
        let original = "Résumé: café 🙂."
        let replacement = "e\u{0301}👋🏽"
        let io = IO(readText: original), fixture = try await makeFixture(io)
        let host = try await makeHost(fixture, io: io)
        defer { close(host, fixture: fixture, io: io) }
        let reviewID = fixture.coordinator.session.id
        let undo = try XCTUnwrap(host.editor.undoManager)
        XCTAssertTrue(host.window.makeFirstResponder(host.editor))

        let originalBytes = Data(original.utf8)
        let range = (original as NSString).range(of: "café")
        XCTAssertNotEqual(range.location, NSNotFound)
        host.editor.setSelectedRange(range)
        let replacementRange = range
        host.editor.setMarkedText(replacement,
            selectedRange: NSRange(location: (replacement as NSString).length, length: 0),
            replacementRange: replacementRange)
        let expected = (original as NSString).replacingCharacters(in: replacementRange, with: replacement)
        XCTAssertTrue(host.editor.hasMarkedText())
        XCTAssertEqual(Data(host.editor.string.utf8), Data(expected.utf8),
                       "Native marked replacement must use the selected UTF-16 range")
        XCTAssertEqual(Data(fixture.coordinator.editedText.utf8), originalBytes,
                       "The composition is still unpublished before Save commits it")
        let committedSelection = NSRange(location: range.location + (replacement as NSString).length, length: 0)

        io.saveAccepted = false
        fixture.coordinator.saveTranscript()
        try await refresh(host.view)
        XCTAssertEqual(io.saveChoosers, 1)
        XCTAssertEqual(io.written.value, [])
        XCTAssertEqual(Data(host.editor.string.utf8), Data(expected.utf8))
        XCTAssertEqual(Data(fixture.coordinator.editedText.utf8), Data(expected.utf8))
        XCTAssertEqual(host.editor.selectedRange(), committedSelection)
        XCTAssertTrue(fixture.coordinator.hasUnsavedReview)
        XCTAssertEqual(fixture.coordinator.session.id, reviewID)
        XCTAssertTrue(host.editor.undoManager === undo)

        io.saveAccepted = true
        fixture.coordinator.saveTranscript()
        await waitForOperation(fixture)
        try await refresh(host.view)
        XCTAssertEqual(io.saveChoosers, 2)
        XCTAssertEqual(io.written.value.map { Data($0.utf8) }, [Data(expected.utf8)])
        XCTAssertFalse(fixture.coordinator.hasUnsavedReview)
        XCTAssertEqual(Data(host.editor.string.utf8), Data(expected.utf8))
        XCTAssertEqual(host.editor.selectedRange(), committedSelection)
    }

    @MainActor func testQuitDecisionPendingPublicationReentryIsCoalesced() async throws {
        let io = IO(), fixture = try await makeFixture(io)
        let host = try await makeHost(fixture, io: io)
        defer { close(host, fixture: fixture, io: io) }
        fixture.coordinator.editedText += " changed"
        try await refresh(host.view)
        XCTAssertTrue(fixture.coordinator.hasUnsavedReview)

        var reentered = false
        var armReentry = true
        let observation = fixture.coordinator.objectWillChange.sink {
            guard armReentry else { return }
            armReentry = false
            reentered = true
            // Setup/binding publications have settled. Reenter on the first
            // @Published willChange emitted by the Quit decision transition.
            fixture.coordinator.quit()
        }
        defer { observation.cancel() }

        fixture.coordinator.quit()
        try await refresh(host.view)
        XCTAssertTrue(reentered, "The observer must reenter at the first Quit publication")
        XCTAssertEqual(io.quitConfirmations, 1,
                       "One Quit attempt must produce only one review decision")
        XCTAssertEqual(fixture.terminationCalls, 0)
        XCTAssertTrue(fixture.coordinator.hasUnsavedReview)

        // A fresh Quit after cancellation must still be admitted, proving the
        // reentrant attempt did not leave the decision state stuck pending.
        let confirmationsBeforeFreshQuit = io.quitConfirmations
        fixture.coordinator.quit()
        XCTAssertEqual(io.quitConfirmations, confirmationsBeforeFreshQuit + 1,
                       "Cancel must clear the pending state so a fresh Quit is admitted")
        XCTAssertEqual(io.quitConfirmations, 2)
        XCTAssertEqual(fixture.terminationCalls, 0)
        XCTAssertTrue(fixture.coordinator.hasUnsavedReview)
    }

    @MainActor func testDirectQuitCommitsMarkedTextBeforeDirtyDecisionAndCoalescesReentry() async throws {
        let io = IO(), fixture = try await makeFixture(io)
        let host = try await makeHost(fixture, io: io)
        defer { close(host, fixture: fixture, io: io) }
        let bound = fixture.coordinator.editedText, reviewID = fixture.coordinator.session.id
        let expected = try compose(" composition", in: host, fixture: fixture, bound: bound)
        var publications = 0
        let observation = fixture.coordinator.$editedText.dropFirst().sink { incoming in
            guard Data(incoming.utf8) == Data(expected.utf8), publications == 0 else { return }
            publications += 1
            // Reenter at the genuine @Published willSet boundary. This is the
            // same Quit intent and must not produce a duplicate decision.
            fixture.coordinator.quit()
        }
        defer { observation.cancel() }
        fixture.coordinator.quit()
        try await refresh(host.view)
        XCTAssertEqual(publications, 1, "Direct Quit must commit through the real binding publisher")
        XCTAssertEqual(io.quitConfirmations, 1, "The committed composition requires one dirty-review decision")
        XCTAssertEqual(io.quitObservedText.map { Data($0.utf8) }, [Data(expected.utf8)])
        XCTAssertEqual(fixture.coordinator.session.id, reviewID)
        XCTAssertTrue(fixture.coordinator.hasUnsavedReview)
        XCTAssertEqual(fixture.terminationCalls, 0, "Cancel preserves the newly committed review")
        XCTAssertEqual(io.saveChoosers, 0)
        XCTAssertEqual(Data(host.editor.string.utf8), Data(expected.utf8))
        XCTAssertEqual(Data(fixture.coordinator.editedText.utf8), Data(expected.utf8))
        XCTAssertFalse(host.editor.hasMarkedText())
        XCTAssertTrue(io.written.value.isEmpty)
    }

    @MainActor private func verifyPublishedReentryIsCancelled(privacy: Bool) async throws {
        let io = IO(), fixture = try await makeFixture(io)
        let host = try await makeHost(fixture, io: io)
        defer { close(host, fixture: fixture, io: io) }
        let bound = fixture.coordinator.editedText, reviewID = fixture.coordinator.session.id
        let expected = try compose(" composition", in: host, fixture: fixture, bound: bound)
        var publications = 0
        let observation = fixture.coordinator.$editedText.dropFirst().sink { incoming in
            guard Data(incoming.utf8) == Data(expected.utf8), publications == 0 else { return }
            publications += 1
            XCTAssertEqual(Data(fixture.coordinator.editedText.utf8), Data(bound.utf8),
                           "Exercise the genuine @Published willSet boundary, not a later callback")
            XCTAssertTrue(fixture.coordinator.busy)
            XCTAssertFalse(fixture.coordinator.transcriptFilePending,
                           "The native editor must remain enabled until its binding commits")
            fixture.coordinator.saveTranscript()
            fixture.coordinator.openTranscript()
            fixture.coordinator.discard()
            fixture.coordinator.unload()
            fixture.coordinator.quit()
            if privacy { fixture.coordinator.interruptForPrivacy() }
            else { fixture.coordinator.cancel() }
        }
        defer { observation.cancel() }
        fixture.coordinator.saveTranscript()
        try await refresh(host.view)
        XCTAssertEqual(publications, 1, "The production commit must actually publish")
        XCTAssertEqual(io.openChoosers, 1, "Reentrant Open was rejected before a chooser")
        XCTAssertEqual(io.saveChoosers, 0)
        XCTAssertEqual(io.quitConfirmations, 0, "Later Cancel/privacy revokes queued Quit")
        XCTAssertTrue(io.written.value.isEmpty)
        XCTAssertEqual(fixture.coordinator.session.id, reviewID)
        XCTAssertEqual(Data(host.editor.string.utf8), Data(expected.utf8))
        XCTAssertEqual(Data(fixture.coordinator.editedText.utf8), Data(expected.utf8))
        XCTAssertTrue(fixture.coordinator.hasUnsavedReview)
        XCTAssertFalse(fixture.coordinator.busy)
        fixture.coordinator.saveTranscript()
        await waitForOperation(fixture)
        XCTAssertEqual(io.saveChoosers, 1)
        XCTAssertEqual(io.written.value.map { Data($0.utf8) }, [Data(expected.utf8)])
        XCTAssertFalse(fixture.coordinator.hasUnsavedReview)
    }
    @MainActor func testPublishedCommitRejectsReentryAndCancelRevokesQueuedQuit() async throws {
        try await verifyPublishedReentryIsCancelled(privacy: false)
    }
    @MainActor func testPublishedCommitPrivacyInterruptionRevokesQueuedQuit() async throws {
        try await verifyPublishedReentryIsCancelled(privacy: true)
    }

    @MainActor func testReentrantQuitWaitsForCommittedBytesAndRunsDecisionOnce() async throws {
        let io = IO(), fixture = try await makeFixture(io)
        let host = try await makeHost(fixture, io: io)
        defer { close(host, fixture: fixture, io: io) }
        let bound = fixture.coordinator.editedText, reviewID = fixture.coordinator.session.id
        let expected = try compose(" composition", in: host, fixture: fixture, bound: bound)
        var publications = 0
        let observation = fixture.coordinator.$editedText.dropFirst().sink { incoming in
            guard Data(incoming.utf8) == Data(expected.utf8), publications == 0 else { return }
            publications += 1
            XCTAssertEqual(Data(fixture.coordinator.editedText.utf8), Data(bound.utf8))
            fixture.coordinator.quit()
            fixture.coordinator.quit()
        }
        defer { observation.cancel() }
        fixture.coordinator.saveTranscript()
        try await refresh(host.view)
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(io.quitConfirmations, 1)
        XCTAssertEqual(io.quitObservedText.map { Data($0.utf8) }, [Data(expected.utf8)])
        XCTAssertEqual(io.saveChoosers, 0)
        XCTAssertTrue(io.written.value.isEmpty)
        XCTAssertEqual(fixture.coordinator.session.id, reviewID)
        XCTAssertEqual(Data(host.editor.string.utf8), Data(expected.utf8))
        XCTAssertEqual(Data(fixture.coordinator.editedText.utf8), Data(expected.utf8))
        XCTAssertTrue(fixture.coordinator.hasUnsavedReview)
        XCTAssertFalse(fixture.coordinator.busy)
    }

    @MainActor func testPreparationFenceSurvivesRealFileAdmissionWillChange() async throws {
        let io = IO(), fixture = try await makeFixture(io)
        let host = try await makeHost(fixture, io: io)
        defer { close(host, fixture: fixture, io: io) }
        let bound = fixture.coordinator.editedText, reviewID = fixture.coordinator.session.id
        let expected = try compose(" composition", in: host, fixture: fixture, bound: bound)
        var admissionPublications = 0
        let observation = fixture.coordinator.objectWillChange.sink {
            // The editedText willSet still exposes `bound` and is excluded.
            // Once its setter finishes, the next real publication is file
            // admission's willSet: the new token is not yet readable here.
            guard admissionPublications == 0,
                  Data(fixture.coordinator.editedText.utf8) == Data(expected.utf8),
                  !fixture.coordinator.transcriptFilePending else { return }
            admissionPublications += 1
            XCTAssertTrue(fixture.coordinator.busy, "Preparation must bridge file admission's willSet")
            fixture.coordinator.saveTranscript()
            fixture.coordinator.openTranscript()
            fixture.coordinator.cancel()
        }
        defer { observation.cancel() }
        fixture.coordinator.saveTranscript()
        try await refresh(host.view)
        XCTAssertEqual(admissionPublications, 1, "Exercise the actual postcommit admission publication")
        XCTAssertEqual(io.openChoosers, 1)
        XCTAssertEqual(io.saveChoosers, 0)
        XCTAssertTrue(io.written.value.isEmpty)
        XCTAssertEqual(fixture.coordinator.session.id, reviewID)
        XCTAssertEqual(Data(fixture.coordinator.editedText.utf8), Data(expected.utf8))
        XCTAssertEqual(Data(host.editor.string.utf8), Data(expected.utf8))
        XCTAssertTrue(fixture.coordinator.hasUnsavedReview)
        XCTAssertFalse(fixture.coordinator.busy)
    }

    @MainActor func testConflictingHostCompositionsFailClosedAndRetiredEditorsCannotOverwriteReplacement() async throws {
        let io = IO(), fixture = try await makeFixture(io)
        let first = try await makeHost(fixture, io: io)
        defer { close(first, fixture: fixture, io: io) }
        let second = try await makeHost(fixture, io: io)
        defer { close(second, fixture: fixture, io: io) }
        let bound = fixture.coordinator.editedText
        let firstText = try compose(" first", in: first, fixture: fixture, bound: bound)
        let secondText = try compose(" second", in: second, fixture: fixture, bound: bound)
        fixture.coordinator.saveTranscript()
        try await refresh(first.view)
        try await refresh(second.view)
        XCTAssertEqual(io.saveChoosers, 0)
        XCTAssertTrue(io.written.value.isEmpty)
        XCTAssertEqual(Data(first.editor.string.utf8), Data(firstText.utf8))
        XCTAssertEqual(Data(second.editor.string.utf8), Data(secondText.utf8))
        XCTAssertTrue(first.editor.hasMarkedText())
        XCTAssertTrue(second.editor.hasMarkedText())
        XCTAssertEqual(Data(fixture.coordinator.editedText.utf8), Data(bound.utf8))
        XCTAssertFalse(fixture.coordinator.busy)

        // A real edit from the other host supersedes the first host's older
        // synchronized baseline. Before SwiftUI refreshes that stale host, Save
        // must not commit its obsolete composition over the newer shared text.
        second.editor.unmarkText()
        XCTAssertEqual(Data(fixture.coordinator.editedText.utf8), Data(secondText.utf8))
        XCTAssertTrue(first.editor.hasMarkedText())
        fixture.coordinator.saveTranscript()
        XCTAssertEqual(io.saveChoosers, 0)
        XCTAssertTrue(io.written.value.isEmpty)
        XCTAssertEqual(Data(fixture.coordinator.editedText.utf8), Data(secondText.utf8))
        try await refresh(first.view)
        try await refresh(second.view)
        XCTAssertEqual(Data(first.editor.string.utf8), Data(secondText.utf8))

        // Deliberate existing Open/replacement acceptance creates a new review;
        // the old native views are retained only to probe their teardown boundary.
        io.readText.value = "Synthetic replacement review."
        fixture.coordinator.openTranscript()
        await waitForOperation(fixture)
        try await refresh(first.view)
        try await refresh(second.view)
        XCTAssertNil(first.editor.delegate)
        XCTAssertNil(second.editor.delegate)
        let replacement = try XCTUnwrap(editor(in: first.view))
        XCTAssertFalse(replacement === first.editor)
        first.editor.setMarkedText(" obsolete", selectedRange: NSRange(location: 9, length: 0),
            replacementRange: NSRange(location: (first.editor.string as NSString).length, length: 0))
        XCTAssertTrue(first.editor.hasMarkedText(), "Establish an actual retired native composition")
        XCTAssertNotEqual(Data(first.editor.string.utf8), Data(fixture.coordinator.editedText.utf8))
        XCTAssertEqual(fixture.coordinator.editedText, "Synthetic replacement review.")
        fixture.coordinator.saveTranscript()
        await waitForOperation(fixture)
        XCTAssertEqual(io.saveChoosers, 1)
        XCTAssertEqual(io.written.value, ["Synthetic replacement review."])
        XCTAssertEqual(fixture.coordinator.editedText, "Synthetic replacement review.")
        XCTAssertFalse(fixture.coordinator.hasUnsavedReview)
        XCTAssertEqual(io.quitConfirmations, 0)
    }
}
