import AppKit
import Combine
import QuartzCore
import SwiftUI
import XCTest
@testable import ClavuneApp
@testable import ClavuneCore

/// Opt-in static content renders. Hidden, non-key test-owned views only.
/// The manifest explicitly says motion/calibration and real-window acceptance
/// are not captured; a PNG or deterministic layer test is not motion evidence.
final class QAContentRenderTests: XCTestCase {
    private enum RenderFailure: Error { case bitmap, unsettled, forbiddenBoundary }

    @MainActor private func navigation(in view: NSView) -> NSSegmentedControl? {
        if let control = view as? NSSegmentedControl, control.segmentCount == 3,
           ["Statistics", "Statistiken"].contains(control.label(forSegment: 2) ?? "") { return control }
        for child in view.subviews {
            if let found = navigation(in: child) { return found }
        }
        return nil
    }
    @MainActor private func scrollViews(in view: NSView) -> [NSScrollView] {
        let current = (view as? NSScrollView).map { [$0] } ?? []
        return current + view.subviews.flatMap { scrollViews(in: $0) }
    }
    @MainActor private func advance(_ host: NSView) async {
        host.layoutSubtreeIfNeeded()
        let turn = expectation(description: "one hidden-host layout turn")
        DispatchQueue.main.async { turn.fulfill() }
        await fulfillment(of: [turn], timeout: 2)
        host.layoutSubtreeIfNeeded()
    }
    @MainActor private func waitForStatistics(_ model: LocalStatisticsPageModel) async throws {
        if case .loading = model.state {
            let ready = expectation(description: "synthetic Statistics preview settled")
            let observation = model.$state.filter { state in
                if case .loading = state { return false }; return true
            }.prefix(1).sink { _ in ready.fulfill() }
            let result = await XCTWaiter.fulfillment(of: [ready], timeout: 3)
            observation.cancel()
            guard result == .completed else { throw RenderFailure.unsettled }
        }
        switch model.state {
        case .populated, .partial, .empty: break
        default: throw RenderFailure.unsettled
        }
    }
    @MainActor private func waitForReview(_ fixture: QARenderIsolationFixture, text: String) async throws {
        let ready = expectation(description: "in-memory document operation drained")
        let observation = fixture.coordinator.$operationPending.filter { !$0 }.prefix(1)
            .sink { _ in ready.fulfill() }
        let result = await XCTWaiter.fulfillment(of: [ready], timeout: 2)
        observation.cancel()
        guard result == .completed else { throw RenderFailure.unsettled }
        XCTAssertEqual(fixture.coordinator.session.phase, .review)
        XCTAssertEqual(fixture.coordinator.session.rawTranscript, text)
        XCTAssertEqual(fixture.coordinator.editedText, text)
        fixture.assertSafe()
    }
    @MainActor private func select(_ index: Int, in host: NSView) async throws {
        let control = try XCTUnwrap(navigation(in: host), "QA navigation was not mounted")
        let action = try XCTUnwrap(control.action)
        control.selectedSegment = index
        XCTAssertTrue(control.sendAction(action, to: control.target))
        await advance(host)
        XCTAssertEqual(control.selectedSegment, index)
    }
    @MainActor private func host(_ view: DictationView, width: CGFloat, height: CGFloat)
        -> (NSWindow, NSHostingView<AnyView>) {
        let window = NSWindow(contentRect: NSRect(x: 220, y: 250, width: width, height: height),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("main")
        // The OS accessibility environment is read-only. This app-local seam
        // only strengthens motion reduction, without changing a system setting.
        let hosting = NSHostingView(rootView: AnyView(view.environment(\.observatoryForceReducedMotion, true)))
        window.contentView = hosting
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        return (window, hosting)
    }
    @MainActor private func verifyIsolation(_ window: NSWindow, fixture: QARenderIsolationFixture,
                                            keyBefore: NSWindow?, mainBefore: NSWindow?) throws {
        fixture.assertSafe()
        guard fixture.forbidden.calls.isEmpty,
              fixture.coordinator.microphone.state == .closed,
              !fixture.coordinator.operationPending, !fixture.coordinator.closePending,
              !fixture.coordinator.canStart, fixture.coordinator.launchConfiguration.isQA,
              !window.isVisible, !window.isKeyWindow, !window.isMainWindow,
              NSApp.keyWindow === keyBefore, NSApp.mainWindow === mainBefore else {
            throw RenderFailure.forbiddenBoundary
        }
    }
    @MainActor private func saveContent(_ host: NSView, name: String, output: QAContentEvidenceOutput,
        fixture: QARenderIsolationFixture, keyBefore: NSWindow?, mainBefore: NSWindow?) throws
        -> QAContentRenderEvidence.Image {
        let window = try XCTUnwrap(host.window)
        try verifyIsolation(window, fixture: fixture, keyBefore: keyBefore, mainBefore: mainBefore)
        try verifyReducedMotion(in: host)
        guard host.bounds.width.isFinite, host.bounds.height.isFinite,
              host.bounds.width > 0, host.bounds.height > 0,
              host.bounds.width <= 2048, host.bounds.height <= 2048 else { throw RenderFailure.bitmap }
        // Explicit 2x raster independent of the test machine's backing display.
        let pixelsWide = Int((host.bounds.width * 2).rounded())
        let pixelsHigh = Int((host.bounds.height * 2).rounded())
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw RenderFailure.bitmap
        }
        bitmap.size = host.bounds.size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try verifyReducedMotion(in: host)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw RenderFailure.bitmap }
        let filename = name + ".png"
        try verifyIsolation(window, fixture: fixture, keyBefore: keyBefore, mainBefore: mainBefore)
        try output.write(data, name: filename)
        try verifyIsolation(window, fixture: fixture, keyBefore: keyBefore, mainBefore: mainBefore)
        let observedReducedMotion = try verifyReducedMotion(in: host)
        print("OFFSCREEN_CONTENT_RENDER \(name) \(output.directory.appendingPathComponent(filename).path) \(data.count) bytes")
        return QAContentRenderEvidence.Image(file: filename, sha256: QAContentSourceBinding.sha256(data),
            bytes: data.count, widthPoints: Double(host.bounds.width), heightPoints: Double(host.bounds.height),
            widthPixels: bitmap.pixelsWide, heightPixels: bitmap.pixelsHigh, reduceMotion: observedReducedMotion)
    }
    /// Read the mounted production control, not just the requested environment.
    /// This remains endpoint/action-policy evidence, never compositor calibration.
    @discardableResult
    @MainActor private func verifyReducedMotion(in host: NSView) throws -> Bool {
        let control = try XCTUnwrap(navigation(in: host) as? InkSegmentedControl)
        let underline = try XCTUnwrap(control.layer?.sublayers?.first {
            $0.name == "clavune.navigation.underline"
        })
        guard control.reducedMotion,
              underline.animation(forKey: "clavune.selection") == nil else {
            XCTFail("Static capture requires effective reduced motion and no selection action")
            throw RenderFailure.forbiddenBoundary
        }
        return control.reducedMotion
    }
    @MainActor private func scrollToEnd(_ host: NSView) async throws {
        let scroll = try XCTUnwrap(scrollViews(in: host).first(where: { $0.documentView != nil }))
        let clip = scroll.contentView
        let document = try XCTUnwrap(scroll.documentView)
        let maxY = max(0, document.frame.height - clip.bounds.height)
        XCTAssertTrue(maxY.isFinite)
        clip.scroll(to: NSPoint(x: 0, y: maxY))
        scroll.reflectScrolledClipView(clip)
        await advance(host)
        XCTAssertEqual(clip.bounds.minX, 0, accuracy: 1)
        XCTAssertEqual(clip.bounds.minY, maxY, accuracy: 1,
                       "The last content row must be reachable, not just cropped out of a still")
    }

    @MainActor func testRenderSyntheticDictationReviewSettingsAndStatisticsAtTwoWidths() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["CLAVUNE_RUN_UI_HOST_FIXTURES"] == "1" &&
                          environment["CLAVUNE_RENDER_QA_CONTENT"] == "1",
                          "Run only for explicitly requested synthetic app-content visual review")
        // Verify source inputs before constructing AppKit views or coordinator.
        let source = try QAContentSourceBinding.verify(environment: environment,
                                                       testBundle: Bundle(for: QAContentRenderTests.self))
        let output = try QAContentEvidenceOutput(path: XCTUnwrap(environment["CLAVUNE_QA_RENDER_OUTPUT"]))
        _ = NSApplication.shared
        let keyBefore = NSApp.keyWindow, mainBefore = NSApp.mainWindow
        let fixture = try QARenderIsolationFixture()
        fixture.assertSafe()
        var images: [QAContentRenderEvidence.Image] = []
        func capture(_ view: NSView, _ name: String) throws {
            images.append(try saveContent(view, name: name, output: output, fixture: fixture,
                                          keyBefore: keyBefore, mainBefore: mainBefore))
        }

        for width: CGFloat in [560, 780] {
            let (window, view) = host(DictationView(coordinator: fixture.coordinator),
                                      width: width, height: QAWindowLayout.compactHeight)
            defer { window.close() }
            await advance(view)
            XCTAssertEqual(fixture.coordinator.session.phase, .idle)
            XCTAssertNil(fixture.coordinator.model, "The preview must not invent a ready model")
            try capture(view, "dictation-idle-\(Int(width))")
        }
        for width: CGFloat in [560, 780] {
            let (window, view) = host(DictationView(coordinator: fixture.coordinator),
                                      width: width, height: QAWindowLayout.expandedHeight)
            defer { window.close() }
            await advance(view)
            try await select(1, in: view)
            try capture(view, "settings-top-\(Int(width))")
            try await scrollToEnd(view)
            try capture(view, "settings-end-\(Int(width))")
        }
        for width: CGFloat in [560, 780] {
            let statisticsModel = LocalStatisticsPageModel(
                loader: { period in try await LocalStatisticsSyntheticPreview.load(period) },
                now: { LocalStatisticsSyntheticPreview.referenceTime })
            defer { statisticsModel.leave() }
            let (window, view) = host(DictationView(coordinator: fixture.coordinator,
                statisticsPreviewInQA: true, statisticsPreviewModel: statisticsModel),
                width: width, height: QAWindowLayout.expandedHeight)
            defer { window.close() }
            await advance(view)
            try await select(2, in: view)
            try await waitForStatistics(statisticsModel)
            await advance(view)
            try capture(view, "statistics-seven-days-\(Int(width))")
            try await scrollToEnd(view)
            try capture(view, "statistics-end-\(Int(width))")
        }
        for (state, transcript) in [("review", QARenderIsolationFixture.transcript),
                                     ("review-long", QARenderIsolationFixture.longTranscript)] {
            if fixture.coordinator.hasPendingReview { fixture.coordinator.discard() }
            fixture.openReview(transcript)
            try await waitForReview(fixture, text: transcript)
            let reviewID = fixture.coordinator.session.id
            for width: CGFloat in [560, 780] {
                let height = QAWindowLayout.reviewSize(forUTF8Bytes: transcript.utf8.count).window
                let (window, view) = host(DictationView(coordinator: fixture.coordinator), width: width, height: height)
                defer { window.close() }
                await advance(view)
                // Repeat interrupted navigation without replacing review identity.
                for index in [1, 0, 1, 0] { try await select(index, in: view) }
                XCTAssertEqual(fixture.coordinator.session.id, reviewID)
                XCTAssertEqual(fixture.coordinator.editedText, transcript)
                try capture(view, "\(state)-\(Int(width))")
            }
        }
        fixture.assertSafe()
        XCTAssertTrue(NSApp.keyWindow === keyBefore)
        XCTAssertTrue(NSApp.mainWindow === mainBefore)
        let sourceAfter = try QAContentSourceBinding.verify(environment: environment,
                                                            testBundle: Bundle(for: QAContentRenderTests.self))
        XCTAssertEqual(sourceAfter.sourceManifestSHA256, source.sourceManifestSHA256)
        XCTAssertEqual(sourceAfter.testBundleExecutableSHA256, source.testBundleExecutableSHA256)
        let evidence = QAContentRenderEvidence(source: source, forbiddenBoundaryCalls: fixture.forbidden.calls,
                                                images: images)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try output.write(try encoder.encode(evidence), name: "render-evidence.json")
    }
}
