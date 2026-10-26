import Foundation
import Dispatch
import XCTest
@testable import ClavuneApp
@testable import ClavuneCore

/// Only injected chooser/writer closures run. No real panel, journal, or file.
final class LocalStatisticsExportControllerTests: UIFixtureAssertions {
    @MainActor private final class Selection {
        var value: LocalStatisticsPeriod = .last7Days
    }
    private final class Writes: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func add(_ text: String) { lock.lock(); defer { lock.unlock() }; values.append(text) }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return values }
    }
    private final class HeldWriter: @unchecked Sendable {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let writes = Writes()
        func write(_ text: String) {
            writes.add(text)
            started.signal()
            release.wait()
        }
        func awaitStart() -> Bool { started.wait(timeout: .now() + 5) == .success }
    }
    private struct SyntheticWriteFailure: Error {}

    private func input() throws -> LocalStatisticsJSONExport.Input {
        let now = Date(timeIntervalSince1970: 1_000_000.125)
        let period = try LocalStatisticsPeriod.last7Days.interval(endingAt: now)
        let report = try LocalStatisticsSummaryBuilder.build(events: [], period: period)
        var diagnostics = LocalStatisticsReadDiagnostics()
        diagnostics.readerState = .validEmpty
        let result = LocalStatisticsLoadResult(report: report, diagnostics: diagnostics, loadedAt: now)
        return .init(displayState: .empty, selection: .last7Days, result: result)
    }

    @MainActor func testChooserCancellationDoesNotWriteOrClaimSuccess() async throws {
        let writes = Writes()
        let environment = LocalStatisticsExportEnvironment(
            chooseDestination: { _, _ in nil },
            writeJSON: { text, _ in writes.add(text) })
        let controller = LocalStatisticsExportController(environment: environment,
                                                          gate: LocalStatisticsExportGate())
        await controller.export(try input(), ui: .german)
        XCTAssertEqual(controller.state, .chooserCancelled)
        XCTAssertTrue(writes.all.isEmpty)
    }

    @MainActor func testCancelledTaskReturningFromChooserNeverStartsDetachedWriter() async throws {
        let writes = Writes()
        let destination = URL(fileURLWithPath: "/tmp/synthetic-statistics-only.json")
        let environment = LocalStatisticsExportEnvironment(
            chooseDestination: { _, _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return destination
            },
            writeJSON: { text, _ in writes.add(text) })
        let controller = LocalStatisticsExportController(environment: environment,
                                                          gate: LocalStatisticsExportGate())
        let snapshot = try input()
        let operation = Task { await controller.export(snapshot, ui: .german) }
        await operation.value
        XCTAssertEqual(controller.state, .cancelledBeforeWrite)
        XCTAssertTrue(writes.all.isEmpty)
    }

    @MainActor func testThrownWriterNeverReportsSavedOrReviewSave() async throws {
        let destination = URL(fileURLWithPath: "/tmp/synthetic-statistics-only.json")
        let environment = LocalStatisticsExportEnvironment(
            chooseDestination: { _, _ in destination },
            writeJSON: { _, _ in throw SyntheticWriteFailure() })
        let controller = LocalStatisticsExportController(environment: environment,
                                                          gate: LocalStatisticsExportGate())
        await controller.export(try input(), ui: .german)
        XCTAssertEqual(controller.state, .writeOutcomeUncertain)
        // The export boundary has no AppCoordinator, reviewAction or journal
        // injection: this failure can never become a transcript Save metric.
    }

    @MainActor func testExplicitExportWritesOnlyClickedSnapshotThroughFakeWriter() async throws {
        let writes = Writes()
        let selection = Selection()
        let destination = URL(fileURLWithPath: "/tmp/synthetic-statistics-only.json")
        let environment = LocalStatisticsExportEnvironment(
            chooseDestination: { _, _ in
                // Simulate a period change while the (fake) chooser is open.
                selection.value = .last24Hours
                return destination
            },
            writeJSON: { text, _ in writes.add(text) })
        let controller = LocalStatisticsExportController(environment: environment,
                                                          gate: LocalStatisticsExportGate())
        let clicked = try input()
        XCTAssertTrue(writes.all.isEmpty, "Constructing page/export state must never write")
        await controller.export(clicked, ui: .german,
                                generatedAt: Date(timeIntervalSince1970: 1_000_002.125))
        XCTAssertEqual(controller.state, .saved)
        XCTAssertEqual(selection.value, .last24Hours)
        let text = try XCTUnwrap(writes.all.first)
        XCTAssertEqual(writes.all.count, 1)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let period = try XCTUnwrap(document["period"] as? [String: Any])
        XCTAssertEqual(period["selection"] as? String, "last7Days")
        XCTAssertEqual(period["endExclusiveUnixSeconds"] as? Double, 1_000_000.125)
        XCTAssertEqual(document["readCompletedAtUnixSeconds"] as? Double, 1_000_000.125)
        XCTAssertEqual(document["exportGeneratedAtUnixSeconds"] as? Double, 1_000_002.125)
    }

    @MainActor func testSecondClickOnSameControllerDoesNotStartAnotherWrite() async throws {
        let held = HeldWriter()
        defer { held.release.signal() }
        let choosers = Writes()
        let destination = URL(fileURLWithPath: "/tmp/synthetic-statistics-only.json")
        let environment = LocalStatisticsExportEnvironment(
            chooseDestination: { _, _ in choosers.add("choose"); return destination },
            writeJSON: { text, _ in held.write(text) })
        let controller = LocalStatisticsExportController(environment: environment,
                                                          gate: LocalStatisticsExportGate())
        let snapshot = try input()
        let first = Task { await controller.export(snapshot, ui: .german) }
        let started = await Task.detached { held.awaitStart() }.value
        XCTAssertTrue(started, "Fake writer should enter within bounded test time")
        XCTAssertEqual(controller.state, .writing)
        await controller.export(snapshot, ui: .german)
        XCTAssertEqual(choosers.all.count, 1)
        XCTAssertEqual(held.writes.all.count, 1)
        held.release.signal()
        await first.value
        XCTAssertEqual(controller.state, .saved)
        XCTAssertEqual(held.writes.all.count, 1)
    }

    @MainActor func testSecondHostCannotChooseOrWriteWhileFirstHostExportIsAdmitted() async throws {
        let gate = LocalStatisticsExportGate()
        let held = HeldWriter()
        defer { held.release.signal() }
        let secondWrites = Writes(), secondChoosers = Writes()
        let destination = URL(fileURLWithPath: "/tmp/synthetic-statistics-only.json")
        let first = LocalStatisticsExportController(environment: .init(
            chooseDestination: { _, _ in destination },
            writeJSON: { text, _ in held.write(text) }), gate: gate)
        let second = LocalStatisticsExportController(environment: .init(
            chooseDestination: { _, _ in secondChoosers.add("choose"); return destination },
            writeJSON: { text, _ in secondWrites.add(text) }), gate: gate)
        let clicked = try input()
        let firstTask = Task { await first.export(clicked, ui: .german) }
        let started = await Task.detached { held.awaitStart() }.value
        XCTAssertTrue(started)
        await second.export(clicked, ui: .german)
        XCTAssertEqual(second.state, .anotherExportActive)
        XCTAssertTrue(secondChoosers.all.isEmpty)
        XCTAssertTrue(secondWrites.all.isEmpty)
        held.release.signal()
        await firstTask.value
        XCTAssertEqual(first.state, .saved)
    }

    @MainActor func testQuitClosesPendingChooserBeforeItsLateURLCanWrite() async throws {
        let gate = LocalStatisticsExportGate(), writes = Writes()
        let destination = URL(fileURLWithPath: "/tmp/synthetic-statistics-only.json")
        let controller = LocalStatisticsExportController(environment: .init(
            chooseDestination: { _, _ in
                XCTAssertNil(gate.closeForQuit(), "No writer was admitted by an open chooser")
                return destination
            }, writeJSON: { text, _ in writes.add(text) }), gate: gate)
        await controller.export(try input(), ui: .german)
        XCTAssertEqual(controller.state, .cancelledBeforeWrite)
        XCTAssertTrue(writes.all.isEmpty)
        XCTAssertNil(gate.reserve(), "Quit must permanently close this process gate")
    }

    @MainActor func testCoordinatorQuitWaitsForAdmittedWriterBeforeTermination() async throws {
        let gate = LocalStatisticsExportGate(), held = HeldWriter()
        defer { held.release.signal() }
        let fixture = try CoordinatorFixture(configureEnvironment: { environment in
            environment.closeStatisticsExportsForQuit = { gate.closeForQuit() }
        })
        let destination = URL(fileURLWithPath: "/tmp/synthetic-statistics-only.json")
        let controller = LocalStatisticsExportController(environment: .init(
            chooseDestination: { _, _ in destination },
            writeJSON: { text, _ in held.write(text) }), gate: gate)
        let clicked = try input()
        let exportTask = Task { await controller.export(clicked, ui: .german) }
        let started = await Task.detached { held.awaitStart() }.value
        XCTAssertTrue(started)
        let reachedDrain = expectation(description: "coordinator reached admitted-work drain")
        let terminated = expectation(description: "terminate only after synthetic export drain")
        fixture.quitWillAwaitAdmittedOperation = reachedDrain
        fixture.terminated = terminated
        fixture.coordinator.quit()
        await fulfillment(of: [reachedDrain], timeout: 5)
        XCTAssertEqual(fixture.terminationCalls, 0)
        XCTAssertFalse(fixture.quitTrace.contains(.willUnloadInference))
        XCTAssertFalse(fixture.quitTrace.contains(.terminationRequested))
        XCTAssertNil(gate.reserve(), "Quit closed admission before its first await")
        held.release.signal()
        await exportTask.value
        await fulfillment(of: [terminated], timeout: 5)
        XCTAssertEqual(fixture.terminationCalls, 1)
    }

    @MainActor func testUnsavedReviewQuitCancelDoesNotCloseExportAdmission() async throws {
        let gate = LocalStatisticsExportGate()
        let fixture = try CoordinatorFixture(configureEnvironment: { environment in
            environment.closeStatisticsExportsForQuit = { gate.closeForQuit() }
            environment.confirmUnsavedReviewQuit = { _ in .cancel }
        })
        await startRecording(fixture)
        await stopToReview(fixture)
        fixture.coordinator.editedText = "Synthetic unsaved review"
        XCTAssertTrue(fixture.coordinator.hasUnsavedReview)
        let reviewID = fixture.coordinator.session.id
        fixture.coordinator.quit()
        XCTAssertEqual(fixture.terminationCalls, 0)
        XCTAssertFalse(gate.isClosingForQuit)
        let admission = try XCTUnwrap(gate.reserve())
        gate.finish(admission)
        XCTAssertEqual(fixture.coordinator.session.id, reviewID)
        XCTAssertEqual(fixture.coordinator.editedText, "Synthetic unsaved review")
    }

    @MainActor func testQuitJoinsThrowingWriterBeforeTermination() async throws {
        let gate = LocalStatisticsExportGate(), held = HeldWriter()
        defer { held.release.signal() }
        let fixture = try CoordinatorFixture(configureEnvironment: { environment in
            environment.closeStatisticsExportsForQuit = { gate.closeForQuit() }
        })
        let destination = URL(fileURLWithPath: "/tmp/synthetic-statistics-only.json")
        let controller = LocalStatisticsExportController(environment: .init(
            chooseDestination: { _, _ in destination },
            writeJSON: { text, _ in held.write(text); throw SyntheticWriteFailure() }), gate: gate)
        let clicked = try input()
        let exportTask = Task { await controller.export(clicked, ui: .german) }
        let started = await Task.detached { held.awaitStart() }.value
        XCTAssertTrue(started)
        let reachedDrain = expectation(description: "coordinator reached throwing export drain")
        let terminated = expectation(description: "terminate after throwing synthetic writer exits")
        fixture.quitWillAwaitAdmittedOperation = reachedDrain
        fixture.terminated = terminated
        fixture.coordinator.quit()
        await fulfillment(of: [reachedDrain], timeout: 5)
        XCTAssertEqual(fixture.terminationCalls, 0)
        XCTAssertFalse(fixture.quitTrace.contains(.willUnloadInference))
        XCTAssertFalse(fixture.quitTrace.contains(.terminationRequested))
        held.release.signal()
        await exportTask.value
        await fulfillment(of: [terminated], timeout: 5)
        XCTAssertEqual(controller.state, .writeOutcomeUncertain)
        XCTAssertEqual(fixture.terminationCalls, 1)
    }

    @MainActor func testQuitSaveInsideExportChooserDefersTranscriptPanelAndRejectsLateExportURL() async throws {
        let gate = LocalStatisticsExportGate()
        let exportWrites = Writes(), transcriptChoosers = Writes(), transcriptWrites = Writes()
        let exportURL = URL(fileURLWithPath: "/tmp/synthetic-statistics-only.json")
        let transcriptURL = URL(fileURLWithPath: "/tmp/synthetic-review-only.txt")
        let fixture = try CoordinatorFixture(configureEnvironment: { environment in
            environment.confirmUnsavedReviewQuit = { _ in .save }
            environment.chooseTranscriptToSave = { _ in
                transcriptChoosers.add("choose"); return transcriptURL
            }
            environment.writeTranscript = { text, _ in transcriptWrites.add(text) }
            environment.closeStatisticsExportsForQuit = { gate.closeForQuit() }
            environment.statisticsExportActive = { gate.isActive }
            environment.beginStatisticsExportQuitSave = { gate.beginQuitSave() }
            environment.waitForStatisticsExportIdle = { await gate.waitUntilIdle() }
            environment.finishStatisticsExportQuitSave = { gate.finishQuitSave() }
        })
        await startRecording(fixture)
        await stopToReview(fixture)
        fixture.coordinator.editedText = "Synthetic review to preserve"
        let terminated = expectation(description: "quit after exact review save")
        fixture.terminated = terminated
        let controller = LocalStatisticsExportController(environment: .init(
            chooseDestination: { _, _ in
                fixture.coordinator.quit()
                XCTAssertTrue(transcriptChoosers.all.isEmpty,
                              "Quit Save must not open a nested transcript panel")
                return exportURL
            }, writeJSON: { text, _ in exportWrites.add(text) }), gate: gate)
        await controller.export(try input(), ui: .german)
        XCTAssertEqual(controller.state, .cancelledBeforeWrite)
        await fulfillment(of: [terminated], timeout: 5)
        XCTAssertTrue(exportWrites.all.isEmpty)
        XCTAssertEqual(transcriptChoosers.all.count, 1)
        XCTAssertEqual(transcriptWrites.all, ["Synthetic review to preserve"])
        XCTAssertEqual(fixture.terminationCalls, 1)
    }

    @MainActor func testQuitSaveWaitsForAdmittedStatisticsWriterBeforeTranscriptSave() async throws {
        let gate = LocalStatisticsExportGate(), held = HeldWriter()
        defer { held.release.signal() }
        let transcriptChoosers = Writes(), transcriptWrites = Writes()
        let exportURL = URL(fileURLWithPath: "/tmp/synthetic-statistics-only.json")
        let transcriptURL = URL(fileURLWithPath: "/tmp/synthetic-review-only.txt")
        let fixture = try CoordinatorFixture(configureEnvironment: { environment in
            environment.confirmUnsavedReviewQuit = { _ in .save }
            environment.chooseTranscriptToSave = { _ in
                transcriptChoosers.add("choose"); return transcriptURL
            }
            environment.writeTranscript = { text, _ in transcriptWrites.add(text) }
            environment.closeStatisticsExportsForQuit = { gate.closeForQuit() }
            environment.statisticsExportActive = { gate.isActive }
            environment.beginStatisticsExportQuitSave = { gate.beginQuitSave() }
            environment.waitForStatisticsExportIdle = { await gate.waitUntilIdle() }
            environment.finishStatisticsExportQuitSave = { gate.finishQuitSave() }
        })
        await startRecording(fixture)
        await stopToReview(fixture)
        fixture.coordinator.editedText = "Synthetic review after export drain"
        let terminated = expectation(description: "quit after export and review saves")
        fixture.terminated = terminated
        let controller = LocalStatisticsExportController(environment: .init(
            chooseDestination: { _, _ in exportURL },
            writeJSON: { text, _ in held.write(text) }), gate: gate)
        let snapshot = try input()
        let exportTask = Task { await controller.export(snapshot, ui: .german) }
        let started = await Task.detached { held.awaitStart() }.value
        XCTAssertTrue(started)
        fixture.coordinator.quit()
        XCTAssertFalse(fixture.coordinator.canSaveTranscript,
                       "A document Save must not overlap an admitted export writer")
        XCTAssertTrue(transcriptChoosers.all.isEmpty)
        XCTAssertTrue(transcriptWrites.all.isEmpty)
        XCTAssertEqual(fixture.terminationCalls, 0)
        held.release.signal()
        await exportTask.value
        await fulfillment(of: [terminated], timeout: 5)
        XCTAssertEqual(transcriptChoosers.all.count, 1)
        XCTAssertEqual(transcriptWrites.all, ["Synthetic review after export drain"])
        XCTAssertEqual(fixture.terminationCalls, 1)
    }

    @MainActor func testCancelledQuitSavePickerReleasesExportReservation() async throws {
        let gate = LocalStatisticsExportGate()
        let fixture = try CoordinatorFixture(configureEnvironment: { environment in
            environment.confirmUnsavedReviewQuit = { _ in .save }
            environment.chooseTranscriptToSave = { _ in nil }
            environment.statisticsExportActive = { gate.isActive }
            environment.beginStatisticsExportQuitSave = { gate.beginQuitSave() }
            environment.waitForStatisticsExportIdle = { await gate.waitUntilIdle() }
            environment.finishStatisticsExportQuitSave = { gate.finishQuitSave() }
        })
        await startRecording(fixture)
        await stopToReview(fixture)
        fixture.coordinator.editedText = "Synthetic unsaved review"
        let reviewID = fixture.coordinator.session.id
        fixture.coordinator.quit()
        XCTAssertEqual(fixture.terminationCalls, 0)
        XCTAssertEqual(fixture.coordinator.session.id, reviewID)
        XCTAssertEqual(fixture.coordinator.editedText, "Synthetic unsaved review")
        let renewedAdmission = try XCTUnwrap(gate.reserve(),
            "A cancelled transcript Save must restore later deliberate exports")
        gate.finish(renewedAdmission)
    }
}
