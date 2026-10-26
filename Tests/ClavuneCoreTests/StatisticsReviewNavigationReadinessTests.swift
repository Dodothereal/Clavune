import AppKit
import SwiftUI
import XCTest
@testable import ClavuneApp
@testable import ClavuneCore

/// Sticky release avoids leaking a fake loader continuation if an XCTest
/// unwrap fails while SwiftUI is scheduling the offscreen appearance task.
private actor HeldStatisticsUIRead {
    private var released = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func hold(signal: FixtureValue<XCTestExpectation>) async {
        if released { signal.value.fulfill(); return }
        await withCheckedContinuation { value in
            continuations.append(value)
            signal.value.fulfill()
        }
    }

    func release() {
        released = true
        for continuation in continuations { continuation.resume() }
        continuations.removeAll()
    }
}

/// Opt-in, offscreen source fixture only. It must run solely in the integrator's
/// authorized native UI-host pass; this proposal does not launch or host AppKit.
final class StatisticsReviewNavigationReadinessTests: UIFixtureAssertions {
    @MainActor private func editor(in view: NSView) -> PlainTranscriptTextView? {
        if let candidate = view as? PlainTranscriptTextView, candidate.isEditable { return candidate }
        for child in view.subviews {
            if let found = editor(in: child) { return found }
        }
        return nil
    }

    @MainActor private func navigation(in view: NSView) -> NSSegmentedControl? {
        if let control = view as? NSSegmentedControl, control.segmentCount == 3,
           ["Statistics", "Statistiken"].contains(control.label(forSegment: 2) ?? "") {
            return control
        }
        for child in view.subviews {
            if let found = navigation(in: child) { return found }
        }
        return nil
    }

    @MainActor private func refreshHost(_ host: NSView) async {
        host.layoutSubtreeIfNeeded()
        let updated = expectation(description: "one offscreen host update turn")
        DispatchQueue.main.async { updated.fulfill() }
        await fulfillment(of: [updated], timeout: 2)
        host.layoutSubtreeIfNeeded()
    }

    @MainActor private func select(_ index: Int, in host: NSView) async throws {
        let control = try XCTUnwrap(navigation(in: host), "Three-section navigation not found")
        let action = try XCTUnwrap(control.action)
        control.selectedSegment = index
        XCTAssertTrue(control.sendAction(action, to: control.target))
        await refreshHost(host)
        XCTAssertEqual(control.selectedSegment, index)
    }

    @MainActor func testStatisticsRoundTripPreservesExactEditedReviewAndNativeUndo() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CLAVUNE_RUN_UI_HOST_FIXTURES"] == "1" &&
                          ProcessInfo.processInfo.environment["CLAVUNE_RUN_STATISTICS_UI_FIXTURE"] == "1",
                          "Run only in the authorized, explicitly opted-in macOS in-memory UI-host pass")
        _ = NSApplication.shared
        let keyWindowBefore = NSApp.keyWindow
        let suite = "org.clavune.synthetic-statistics-navigation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let selected = URL(fileURLWithPath: "/synthetic-statistics-review-never-opened.txt")
        let transcriptWrites = FixtureValue(0)
        let audioReads = FixtureValue(0)
        let modelImports = FixtureValue(0)
        let modelDownloads = FixtureValue(0)
        let modelRestores = FixtureValue(0)
        let fixture = try CoordinatorFixture(preferences: defaults, modelSelectionEnabled: false,
            localMetricsJournal: nil, processUsageSnapshot: { nil }, configureEnvironment: { environment in
                environment.chooseTranscriptToOpen = { _ in selected }
                environment.readTranscript = { _ in "Synthetic review" }
                environment.writeTranscript = { _, _ in transcriptWrites.update { $0 += 1 } }
                environment.readAudio = { _, _ in
                    audioReads.update { $0 += 1 }
                    throw AudioFileImporter.Failure.invalidFile
                }
                environment.importManagedModel = { _ in
                    modelImports.update { $0 += 1 }
                    throw DictationError.modelInvalid
                }
                environment.downloadManagedModel = { _, _ in
                    modelDownloads.update { $0 += 1 }
                    throw ModelDownloadFailure.unavailableSource
                }
            }, restoreManagedSelection: { _ in
                modelRestores.update { $0 += 1 }
                throw DictationError.modelInvalid
            })
        fixture.coordinator.uiLanguage = .english
        fixture.coordinator.openTranscript()
        await waitForOperation(fixture)
        let reviewID = fixture.coordinator.session.id
        XCTAssertEqual(fixture.coordinator.session.phase, .review)

        let loadCalls = FixtureValue(0)
        let heldStatisticsRead = HeldStatisticsUIRead()
        let statsRequested = expectation(description: "injected synthetic Statistics loader invoked")
        let requestedSignal = FixtureValue(statsRequested)
        // Release even when a later XCTest unwrap throws. A late loader result
        // after leaving Statistics is deliberately permitted to arrive.
        defer { Task { await heldStatisticsRead.release() } }
        let syntheticLoader: LocalStatisticsPageModel.Loader = { period in
            loadCalls.update { $0 += 1 }
            await heldStatisticsRead.hold(signal: requestedSignal)
            let report = try LocalStatisticsSummaryBuilder.build(events: [], period: period)
            return LocalStatisticsLoadResult(report: report,
                diagnostics: LocalStatisticsReadDiagnostics(),
                loadedAt: Date(timeIntervalSince1970: 1_000_000))
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: DictationView(coordinator: fixture.coordinator,
            statisticsLoader: syntheticLoader).transaction {
                $0.disablesAnimations = true; $0.animation = nil
            })
        window.contentView = host
        await refreshHost(host)
        let original = try XCTUnwrap(editor(in: host))
        XCTAssertTrue(window.makeFirstResponder(original))
        let beforeSelection = (original.string as NSString).range(of: "review")
        XCTAssertNotEqual(beforeSelection.location, NSNotFound)
        original.setSelectedRange(beforeSelection)
        let originalUndo = try XCTUnwrap(original.undoManager)
        originalUndo.beginUndoGrouping()
        original.insertText("edited", replacementRange: beforeSelection)
        originalUndo.endUndoGrouping()
        let afterSelection = original.selectedRange()
        XCTAssertTrue(originalUndo.canUndo)
        XCTAssertEqual(original.string, "Synthetic edited")
        XCTAssertEqual(fixture.coordinator.editedText, "Synthetic edited")
        XCTAssertTrue(fixture.coordinator.hasUnsavedReview)

        try await select(2, in: host)
        await fulfillment(of: [statsRequested], timeout: 2)
        XCTAssertEqual(loadCalls.value, 1)
        XCTAssertTrue(original.enclosingScrollView?.isHidden == true)
        XCTAssertFalse(window.firstResponder === original)
        XCTAssertEqual(fixture.coordinator.session.id, reviewID)
        XCTAssertEqual(fixture.coordinator.editedText, "Synthetic edited")
        XCTAssertEqual(original.selectedRange(), afterSelection)
        XCTAssertTrue(originalUndo.canUndo)

        try await select(0, in: host)
        let returned = try XCTUnwrap(editor(in: host))
        XCTAssertTrue(returned === original, "Statistics is not a new review/editor")
        XCTAssertEqual(returned.string, "Synthetic edited")
        XCTAssertEqual(returned.selectedRange(), afterSelection)
        XCTAssertEqual(fixture.coordinator.session.id, reviewID)
        XCTAssertTrue(fixture.coordinator.hasUnsavedReview)
        XCTAssertEqual(loadCalls.value, 1, "Returning to Dictation must not schedule another Statistics read")
        originalUndo.undo()
        XCTAssertEqual(returned.string, "Synthetic review")
        XCTAssertEqual(fixture.coordinator.editedText, "Synthetic review")
        XCTAssertEqual(returned.selectedRange(), beforeSelection)
        XCTAssertTrue(originalUndo.canRedo)
        originalUndo.redo()
        XCTAssertEqual(returned.string, "Synthetic edited")
        XCTAssertEqual(fixture.coordinator.editedText, "Synthetic edited")
        XCTAssertEqual(returned.selectedRange(), afterSelection)
        XCTAssertEqual(fixture.coordinator.session.id, reviewID)
        await heldStatisticsRead.release()

        XCTAssertEqual(fixture.resources.counts.value.constructed, 0)
        XCTAssertEqual(fixture.inference.counts.value.loads, 0)
        XCTAssertEqual(fixture.inference.counts.value.decodes, 0)
        XCTAssertEqual(fixture.inference.counts.value.unloads, 0)
        XCTAssertEqual(fixture.pickerCalls, 0)
        XCTAssertEqual(fixture.permissionCalls, 0)
        XCTAssertEqual(transcriptWrites.value, 0)
        XCTAssertEqual(audioReads.value, 0)
        XCTAssertEqual(modelImports.value, 0)
        XCTAssertEqual(modelDownloads.value, 0)
        XCTAssertEqual(modelRestores.value, 0)
        XCTAssertTrue(fixture.clipboard.calls.isEmpty)
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(NSApp.keyWindow === keyWindowBefore)
    }

    @MainActor func testEnteringStatisticsCancelsOtherHostsPendingHotkeyRecording() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CLAVUNE_RUN_UI_HOST_FIXTURES"] == "1" &&
                          ProcessInfo.processInfo.environment["CLAVUNE_RUN_STATISTICS_UI_FIXTURE"] == "1",
                          "Run only in the authorized, explicitly opted-in macOS in-memory UI-host pass")
        _ = NSApplication.shared
        let keyWindowBefore = NSApp.keyWindow
        let suite = "org.clavune.synthetic-statistics-hotkey.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = try CoordinatorFixture(preferences: defaults, modelSelectionEnabled: false,
            localMetricsJournal: nil, processUsageSnapshot: { nil })
        let coordinator = fixture.coordinator!
        coordinator.setHotkeyEnabled(true)
        let oldRegistration = try XCTUnwrap(fixture.hotkeyRegistrar.registrations.first)
        XCTAssertTrue(coordinator.beginHotkeyRecording())
        coordinator.setHotkeyChordPending(true) // Synthetic held key in another host.
        XCTAssertEqual(oldRegistration.unregisterCalls, 1)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: DictationView(coordinator: coordinator,
            statisticsLoader: { period in
                let report = try LocalStatisticsSummaryBuilder.build(events: [], period: period)
                return LocalStatisticsLoadResult(report: report,
                    diagnostics: LocalStatisticsReadDiagnostics(),
                    loadedAt: Date(timeIntervalSince1970: 1_000_000))
            }).transaction { $0.disablesAnimations = true; $0.animation = nil })
        window.contentView = host
        await refreshHost(host)
        try await select(2, in: host)

        XCTAssertFalse(coordinator.hotkeyRecording)
        XCTAssertFalse(coordinator.hotkeyEnabled,
                       "A held chord must fail closed when another host enters Statistics")
        XCTAssertEqual(fixture.hotkeyRegistrar.activeCount, 0)
        XCTAssertEqual(fixture.hotkeyRegistrar.shortcuts, [.controlShiftSpace],
                       "The retired chord must not be re-registered under a held key")
        XCTAssertEqual(fixture.resources.counts.value.opened, 0)
        XCTAssertEqual(fixture.permissionCalls, 0)
        XCTAssertTrue(fixture.clipboard.calls.isEmpty)
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(NSApp.keyWindow === keyWindowBefore)
    }
}
