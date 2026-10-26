import AppKit
import Combine
import SwiftUI
import XCTest
@testable import ClavuneApp
@testable import ClavuneCore

/// Layout policy plus an opt-in hidden host. No real microphone, permissions,
/// model weights, filesystem transcript, or general clipboard are involved.
final class ObservatoryCompactPresentationTests: UIFixtureAssertions {
    func testReviewViewportBandsStayBoundedAndAgreeWithEditorPolicy() {
        let cases: [(Int, CGFloat, CGFloat)] = [
            (0, 360, 96), (180, 360, 96), (181, 440, 180),
            (1_200, 440, 180), (1_201, 580, 336), (Int.max, 580, 336),
        ]
        for (bytes, window, editor) in cases {
            let size = QAWindowLayout.reviewSize(forUTF8Bytes: bytes)
            XCTAssertEqual(size.window, window)
            XCTAssertEqual(size.editor, editor)
            XCTAssertEqual(ObservatoryAppearance.reviewEditorMinimumHeight(utf8ByteCount: bytes), editor)
            XCTAssertGreaterThan(window - editor, 240,
                                 "Leave room for pinned controls, context and the original-text disclosure")
        }
        XCTAssertLessThanOrEqual(ObservatoryAppearance.settingsColumnWidth, 560 - 44)
        XCTAssertGreaterThan(ObservatoryAppearance.settingsFieldWidth, ObservatoryAppearance.fieldWidth)
        XCTAssertGreaterThanOrEqual(ObservatoryAppearance.settingsColumnWidth - ObservatoryAppearance.settingsFieldWidth - 16, 220)
        XCTAssertGreaterThan(ObservatoryAppearance.settingsViewportGutter, 0)
        XCTAssertLessThan(ObservatoryAppearance.settingsViewportGutter, ObservatoryAppearance.controlHeight / 2)
        XCTAssertEqual(QAWindowLayout.compactHeight, 200)
        XCTAssertNil(QAWindowLayout.contentHeight(isQA: false, isAuxiliaryPanel: false,
            settingsVisible: false, statisticsVisible: false, phase: .review, busy: false))
        XCTAssertNil(QAWindowLayout.contentHeight(isQA: true, isAuxiliaryPanel: true,
            settingsVisible: false, statisticsVisible: false, phase: .review, busy: false))
        XCTAssertGreaterThanOrEqual(ObservatoryAppearance.controlHeight, 28)
        XCTAssertGreaterThanOrEqual(ObservatoryAppearance.settingRowHeight, ObservatoryAppearance.controlHeight)
    }

    @MainActor private func editableReviews(in view: NSView) -> [PlainTranscriptTextView] {
        let current = (view as? PlainTranscriptTextView).flatMap { $0.isEditable ? $0 : nil }
        return (current.map { [$0] } ?? []) + view.subviews.flatMap { editableReviews(in: $0) }
    }

    @MainActor private func refresh(_ view: NSView) async {
        view.layoutSubtreeIfNeeded()
        let settled = expectation(description: "hidden compact host layout turn")
        DispatchQueue.main.async { settled.fulfill() }
        await fulfillment(of: [settled], timeout: 2)
        view.layoutSubtreeIfNeeded()
    }

    @MainActor private func navigation(in view: NSView) -> NSSegmentedControl? {
        if let control = view as? NSSegmentedControl, control.segmentCount == 3 { return control }
        for child in view.subviews {
            if let control = navigation(in: child) { return control }
        }
        return nil
    }

    @MainActor private func scrollViews(in view: NSView) -> [NSScrollView] {
        let current = (view as? NSScrollView).map { [$0] } ?? []
        return current + view.subviews.flatMap { scrollViews(in: $0) }
    }

    private enum OwnedAXReadFailure: Error, Equatable {
        case unsupportedNode, missing(String), malformed(String), invalidFrame
        case cycle, depthLimit, nodeLimit
    }

    /// Read-only adapter for actual objects returned by this host's AX tree.
    /// SwiftUI may return NSObject nodes without full NSAccessibilityProtocol
    /// conformance. The public, deprecated NSObject attribute API remains their
    /// supported fallback; never inspect private SwiftUI types or set AX values.
    /// https://developer.apple.com/documentation/objectivec/nsobject-swift.class/accessibilityattributevalue(_:)
    @MainActor private struct OwnedAXNode {
        let object: NSObject
        private let modern: (any NSAccessibilityProtocol)?
        private let advertised: Set<NSAccessibility.Attribute>

        init(_ value: Any) throws {
            guard let object = value as? NSObject else { throw OwnedAXReadFailure.unsupportedNode }
            self.object = object
            let modern = object as? NSAccessibilityProtocol
            self.modern = modern
            advertised = modern == nil ? Set(object.accessibilityAttributeNames()) : []
        }

        private func optionalAttribute(_ name: NSAccessibility.Attribute) -> Any? {
            guard advertised.contains(name) else { return nil }
            return object.accessibilityAttributeValue(name)
        }

        private func requiredAttribute(_ name: NSAccessibility.Attribute) throws -> Any {
            guard let value = optionalAttribute(name) else { throw OwnedAXReadFailure.missing(name.rawValue) }
            return value
        }

        func labels() throws -> [String] {
            if let modern { return [modern.accessibilityLabel(), modern.accessibilityTitle()].compactMap { $0 } }
            return try [NSAccessibility.Attribute.description, .title].compactMap { name in
                guard let value = optionalAttribute(name) else { return nil }
                guard let label = value as? String else { throw OwnedAXReadFailure.malformed(name.rawValue) }
                return label
            }
        }

        func children() throws -> [Any] {
            if let modern { return modern.accessibilityChildren() ?? [] }
            guard let value = optionalAttribute(.children) else { return [] }
            guard let children = value as? [Any] else { throw OwnedAXReadFailure.malformed("AXChildren") }
            return children
        }

        func accessibilityValue() -> Any? {
            if let modern { return modern.accessibilityValue() }
            return optionalAttribute(.value)
        }

        func isAccessibilityEnabled() throws -> Bool {
            if let modern { return modern.isAccessibilityEnabled() }
            guard let value = try requiredAttribute(.enabled) as? NSNumber,
                  value.doubleValue == 0 || value.doubleValue == 1 else {
                throw OwnedAXReadFailure.malformed("AXEnabled")
            }
            return value.boolValue
        }

        func accessibilityFrame() throws -> NSRect {
            let frame: NSRect
            if let modern {
                frame = modern.accessibilityFrame()
            } else {
                guard let position = try requiredAttribute(.position) as? NSValue,
                      String(cString: position.objCType) == String(cString: NSValue(point: .zero).objCType),
                      let size = try requiredAttribute(.size) as? NSValue,
                      String(cString: size.objCType) == String(cString: NSValue(size: .zero).objCType) else {
                    throw OwnedAXReadFailure.malformed("AXPosition/AXSize")
                }
                // AppKit's legacy position is LOWER-LEFT, screen-relative points,
                // not AXUIElement's top-left convention. No screen flip is needed.
                // https://developer.apple.com/documentation/appkit/standard-attributes
                frame = NSRect(origin: position.pointValue, size: size.sizeValue)
            }
            guard frame.origin.x.isFinite, frame.origin.y.isFinite,
                  frame.size.width.isFinite, frame.size.height.isFinite,
                  frame.size.width > 0, frame.size.height > 0 else {
                throw OwnedAXReadFailure.invalidFrame
            }
            return frame
        }
    }

    // Traverse only genuine children, with no guessed nodes or fabricated data.
    // A cycle/budget violation is a failure, not a missing-element skip.
    @MainActor private func valueElement(label: String, in root: Any) throws -> OwnedAXNode? {
        var visited = Set<ObjectIdentifier>()
        var active = Set<ObjectIdentifier>()
        func visit(_ value: Any, depth: Int) throws -> OwnedAXNode? {
            guard depth < 32 else { throw OwnedAXReadFailure.depthLimit }
            let node = try OwnedAXNode(value)
            let identity = ObjectIdentifier(node.object)
            guard !active.contains(identity) else { throw OwnedAXReadFailure.cycle }
            if visited.contains(identity) { return nil }
            guard visited.count < 512 else { throw OwnedAXReadFailure.nodeLimit }
            visited.insert(identity)
            active.insert(identity)
            defer { active.remove(identity) }
            if try node.labels().contains(label), node.accessibilityValue() != nil { return node }
            for child in try node.children() {
                if let found = try visit(child, depth: depth + 1) { return found }
            }
            return nil
        }
        return try visit(root, depth: 0)
    }

    /// Synthetic adapter inputs only. These never replace or decorate production
    /// nodes in the DictationView test below.
    private final class LegacyAXFixture: NSObject {
        var values: [NSAccessibility.Attribute: Any] = [:]
        var advertisedNames: [NSAccessibility.Attribute]?
        var reads: [NSAccessibility.Attribute] = []
        override func accessibilityAttributeNames() -> [NSAccessibility.Attribute] {
            advertisedNames ?? Array(values.keys)
        }
        override func accessibilityAttributeValue(_ attribute: NSAccessibility.Attribute) -> Any? {
            reads.append(attribute)
            return values[attribute]
        }
    }

    private final class ModernAXFixture: NSView {
        var axChildren: [Any] = []
        var axLabel: String?
        var axValue: Any?
        var axFrame = NSRect(x: 10, y: 20, width: 228, height: 32)
        var axEnabled = true
        override func accessibilityChildren() -> [Any]? { axChildren }
        override func accessibilityLabel() -> String? { axLabel }
        override func accessibilityTitle() -> String? { nil }
        override func accessibilityValue() -> Any? { axValue }
        override func accessibilityFrame() -> NSRect { axFrame }
        override func isAccessibilityEnabled() -> Bool { axEnabled }
    }

    @MainActor private func legacyAXFixture(label: String = "Fixture control") -> LegacyAXFixture {
        let node = LegacyAXFixture()
        node.values = [.description: label, .value: "On", .enabled: NSNumber(value: true),
                       .position: NSValue(point: NSPoint(x: 10, y: 20)),
                       .size: NSValue(size: NSSize(width: 228, height: 32))]
        return node
    }

    @MainActor func testOwnedAXAdapterReadsModernAndAdvertisedLegacyNodesWithoutCoordinateFlips() throws {
        let modern = ModernAXFixture(frame: .zero)
        modern.axLabel = "Modern control"; modern.axValue = "On"
        let legacy = legacyAXFixture()
        modern.axChildren = [legacy]
        for (label, object) in [("Modern control", modern as NSObject), ("Fixture control", legacy)] {
            let node = try XCTUnwrap(try valueElement(label: label, in: modern))
            XCTAssertTrue(node.object === object)
            XCTAssertEqual(try node.accessibilityFrame(), NSRect(x: 10, y: 20, width: 228, height: 32))
            XCTAssertTrue(try node.isAccessibilityEnabled())
            XCTAssertEqual(node.accessibilityValue() as? String, "On")
        }
        XCTAssertFalse(legacy.reads.contains(.children), "A matched value does not require fabricated child traversal")
        legacy.values[.enabled] = NSNumber(value: false)
        XCTAssertFalse(try OwnedAXNode(legacy).isAccessibilityEnabled())
        modern.axEnabled = false
        XCTAssertFalse(try OwnedAXNode(modern).isAccessibilityEnabled())
    }

    @MainActor func testOwnedAXAdapterRejectsMissingOrMalformedRequiredAttributes() throws {
        let node = legacyAXFixture()
        node.advertisedNames = [.description]
        let reader = try OwnedAXNode(node)
        XCTAssertNil(reader.accessibilityValue(), "Unadvertised backing values must never be read")
        XCTAssertThrowsError(try reader.accessibilityFrame())
        XCTAssertThrowsError(try reader.isAccessibilityEnabled())
        XCTAssertEqual(node.reads, [])
        XCTAssertNil(try valueElement(label: "Fixture control", in: node))
        node.advertisedNames = nil
        node.values[.enabled] = "true"
        XCTAssertThrowsError(try OwnedAXNode(node).isAccessibilityEnabled())
        node.values[.enabled] = NSNumber(value: 2)
        XCTAssertThrowsError(try OwnedAXNode(node).isAccessibilityEnabled())
        node.values[.position] = NSValue(size: NSSize(width: 10, height: 20))
        XCTAssertThrowsError(try OwnedAXNode(node).accessibilityFrame())
        node.values[.position] = NSValue(point: NSPoint(x: 10, y: 20))
        node.values[.size] = NSNumber(value: 32)
        XCTAssertThrowsError(try OwnedAXNode(node).accessibilityFrame())
        node.values[.children] = "not an array"
        XCTAssertThrowsError(try OwnedAXNode(node).children())
        node.values[.description] = NSNumber(value: 7)
        XCTAssertThrowsError(try OwnedAXNode(node).labels())
    }

    @MainActor func testOwnedAXAdapterRejectsNonfiniteAndNonpositiveFramesOnBothPaths() throws {
        let legacy = legacyAXFixture()
        let modern = ModernAXFixture(frame: .zero)
        for frame in [NSRect(x: CGFloat.infinity, y: 20, width: 228, height: 32),
                      NSRect(x: 10, y: CGFloat.nan, width: 228, height: 32),
                      NSRect(x: 10, y: 20, width: 0, height: 32),
                      NSRect(x: 10, y: 20, width: 228, height: -1),
                      NSRect(x: 10, y: 20, width: 228, height: CGFloat.infinity)] {
            modern.axFrame = frame
            legacy.values[.position] = NSValue(point: frame.origin)
            legacy.values[.size] = NSValue(size: frame.size)
            XCTAssertThrowsError(try OwnedAXNode(modern).accessibilityFrame())
            XCTAssertThrowsError(try OwnedAXNode(legacy).accessibilityFrame())
        }
    }

    @MainActor func testOwnedAXAdapterBoundsCyclesDepthAndNodeCountWithoutInventingMatches() throws {
        let root = LegacyAXFixture()
        root.values[.children] = [root]
        XCTAssertThrowsError(try valueElement(label: "absent", in: root)) { error in
            XCTAssertEqual(error as? OwnedAXReadFailure, .cycle)
        }
        root.values.removeAll()
        var tail = root
        for _ in 0..<32 {
            let next = LegacyAXFixture(); tail.values[.children] = [next]; tail = next
        }
        XCTAssertThrowsError(try valueElement(label: "absent", in: root)) { error in
            XCTAssertEqual(error as? OwnedAXReadFailure, .depthLimit)
        }
        root.values[.children] = (0..<512).map { _ in LegacyAXFixture() }
        XCTAssertThrowsError(try valueElement(label: "absent", in: root)) { error in
            XCTAssertEqual(error as? OwnedAXReadFailure, .nodeLimit)
        }
        root.values[.children] = [LegacyAXFixture()]
        XCTAssertNil(try valueElement(label: "absent", in: root))
    }

    @MainActor func testSettingsViewportGutterAndRealEndReachabilityAtBothWidthsAndLanguages() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CLAVUNE_RUN_UI_HOST_FIXTURES"] == "1",
                          "Run only in the authorized offscreen macOS UI fixture pass")
        _ = NSApplication.shared
        let keyBefore = NSApp.keyWindow, mainBefore = NSApp.mainWindow
        for language in UILanguage.allCases {
            for width: CGFloat in [560, 780] {
                let configuration = try AppLaunchConfiguration.parse(environment: [
                    "CLAVUNE_QA_PROFILE": "settings-seam-" + String(UUID().uuidString.prefix(8)),
                    "CLAVUNE_QA_FUNCTIONAL": "synthetic-v1",
                ])
                let fixture = try CoordinatorFixture(launchConfiguration: configuration,
                                                     processUsageSnapshot: { nil })
                fixture.coordinator.uiLanguage = language
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 580),
                                      styleMask: [.titled, .resizable], backing: .buffered, defer: true)
                window.isReleasedWhenClosed = false
                defer { window.close() }
                // A supported, view-local assistive-technology environment exposes
                // SwiftUI's real AX nodes without changing an OS preference.
                let host = NSHostingView(rootView: DictationView(coordinator: fixture.coordinator)
                    .environment(\.accessibilityEnabled, true))
                window.contentView = host
                await refresh(host)
                let control = try XCTUnwrap(navigation(in: host))
                control.selectedSegment = 1
                XCTAssertTrue(control.sendAction(try XCTUnwrap(control.action), to: control.target))
                await refresh(host)
                XCTAssertEqual(control.selectedSegment, 1)
                let scroll = try XCTUnwrap(scrollViews(in: host).first(where: { $0.documentView != nil }))
                let navigationFrame = control.convert(control.bounds, to: host)
                let viewportFrame = scroll.convert(scroll.bounds, to: host)
                let topGap = host.isFlipped
                    ? viewportFrame.minY - navigationFrame.maxY
                    : navigationFrame.minY - viewportFrame.maxY
                let bottomGap = host.isFlipped
                    ? host.bounds.maxY - viewportFrame.maxY
                    : viewportFrame.minY - host.bounds.minY
                XCTAssertEqual(topGap, ObservatoryAppearance.settingsViewportGutter, accuracy: 1,
                    "Scrolling controls must be separated from the pinned navigation, not painted over")
                XCTAssertEqual(bottomGap, ObservatoryAppearance.settingsViewportGutter, accuracy: 1)
                XCTAssertEqual(viewportFrame.width, width - 44, accuracy: 1)

                let clip = scroll.contentView
                let document = try XCTUnwrap(scroll.documentView)
                let maxY = max(0, document.frame.height - clip.bounds.height)
                XCTAssertGreaterThan(maxY, 0, "Exercise an actually overflowing Settings document")
                let viewportOnScreen = window.convertToScreen(clip.convert(clip.bounds, to: nil))
                let languageField = try XCTUnwrap(try valueElement(label: language.text("Oberflächensprache"), in: host))
                let fieldFrame = try languageField.accessibilityFrame()
                XCTAssertEqual(fieldFrame.width, ObservatoryAppearance.settingsFieldWidth, accuracy: 1)
                XCTAssertEqual(fieldFrame.maxX, viewportOnScreen.midX + ObservatoryAppearance.settingsColumnWidth / 2,
                    accuracy: 1, "The bounded Settings column must be centered, not stranded at the wide left edge")
                XCTAssertTrue(viewportOnScreen.insetBy(dx: -1, dy: -1).contains(fieldFrame))
                // Intermediate rows may be partially visible; only native bounds
                // and the pinned chrome are invariant at an arbitrary offset.
                clip.scroll(to: NSPoint(x: 0, y: maxY / 2))
                scroll.reflectScrolledClipView(clip)
                await refresh(host)
                XCTAssertEqual(clip.bounds.minY, maxY / 2, accuracy: 1)
                XCTAssertEqual(control.convert(control.bounds, to: host), navigationFrame)
                clip.scroll(to: NSPoint(x: 0, y: maxY))
                scroll.reflectScrolledClipView(clip)
                await refresh(host)
                XCTAssertEqual(clip.bounds.minX, 0, accuracy: 1)
                XCTAssertEqual(clip.bounds.minY, maxY, accuracy: 1)
                XCTAssertEqual(clip.bounds.maxY, document.frame.height, accuracy: 1,
                    "The gutter must retain native access to the true end, not mask away the last rows")
                XCTAssertEqual(control.convert(control.bounds, to: host), navigationFrame)
                XCTAssertEqual(scroll.convert(scroll.bounds, to: host), viewportFrame)
                let lastControl = try XCTUnwrap(try valueElement(label: language.text("Halten zum Sprechen"), in: host))
                let lastFrame = try lastControl.accessibilityFrame()
                XCTAssertGreaterThanOrEqual(lastFrame.height, ObservatoryAppearance.controlHeight)
                XCTAssertTrue(viewportOnScreen.insetBy(dx: -1, dy: -1).contains(lastFrame),
                    "The final Settings control must be fully reachable inside the actual viewport")
                XCTAssertTrue(try lastControl.isAccessibilityEnabled())
                XCTAssertEqual(lastControl.accessibilityValue() as? String, language.text("An"))
                clip.scroll(to: .zero)
                scroll.reflectScrolledClipView(clip)
                await refresh(host)
                XCTAssertEqual(clip.bounds.minY, 0, accuracy: 1)
                XCTAssertFalse(window.isVisible)
                XCTAssertTrue(NSApp.keyWindow === keyBefore)
                XCTAssertTrue(NSApp.mainWindow === mainBefore)
                XCTAssertEqual(fixture.coordinator.microphone.state, .closed)
                XCTAssertEqual(fixture.resources.counts.value.constructed, 0)
                XCTAssertEqual(fixture.inference.counts.value.loads, 0)
                XCTAssertEqual(fixture.inference.counts.value.decodes, 0)
                XCTAssertEqual(fixture.permissionCalls, 0)
                XCTAssertTrue(fixture.clipboard.calls.isEmpty)
            }
        }
    }

    @MainActor func testStatisticsViewportGutterPreservesSyntheticTrueEndAtBothWidthsAndLanguages() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CLAVUNE_RUN_UI_HOST_FIXTURES"] == "1",
                          "Run only in the authorized offscreen macOS UI fixture pass")
        _ = NSApplication.shared
        let keyBefore = NSApp.keyWindow, mainBefore = NSApp.mainWindow
        for language in UILanguage.allCases {
            for width: CGFloat in [560, 780] {
                let configuration = try AppLaunchConfiguration.parse(environment: [
                    "CLAVUNE_QA_PROFILE": "stats-seam-" + String(UUID().uuidString.prefix(8)),
                    "CLAVUNE_QA_FUNCTIONAL": "synthetic-v1",
                ])
                let fixture = try CoordinatorFixture(launchConfiguration: configuration,
                                                     processUsageSnapshot: { nil })
                fixture.coordinator.uiLanguage = language
                let model = LocalStatisticsPageModel(
                    loader: { period in try await LocalStatisticsSyntheticPreview.load(period) },
                    now: { LocalStatisticsSyntheticPreview.referenceTime })
                let loaded = expectation(description: "in-memory statistics preview ready")
                let observation = model.$state.filter { state in
                    switch state {
                    case .populated, .partial: return true
                    default: return false
                    }
                }.prefix(1).sink { _ in loaded.fulfill() }
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 580),
                                      styleMask: [.titled, .resizable], backing: .buffered, defer: true)
                window.isReleasedWhenClosed = false
                defer { observation.cancel(); model.leave(); window.close() }
                let host = NSHostingView(rootView: DictationView(coordinator: fixture.coordinator,
                    statisticsPreviewInQA: true, statisticsPreviewModel: model))
                window.contentView = host
                await refresh(host)
                let control = try XCTUnwrap(navigation(in: host))
                control.selectedSegment = 2
                XCTAssertTrue(control.sendAction(try XCTUnwrap(control.action), to: control.target))
                let loadedResult = await XCTWaiter.fulfillment(of: [loaded], timeout: 3)
                guard loadedResult == .completed else {
                    XCTFail("Statistics geometry needs a settled synthetic result, not a loading placeholder")
                    return
                }
                observation.cancel()
                await refresh(host)
                XCTAssertEqual(control.selectedSegment, 2)
                switch model.state {
                case .populated(let result), .partial(let result):
                    XCTAssertEqual(result.diagnostics.readFiles, 0)
                default: XCTFail("The measured page must contain the injected preview")
                }
                let scroll = try XCTUnwrap(scrollViews(in: host).first(where: { $0.documentView != nil }))
                let navFrame = control.convert(control.bounds, to: host)
                let viewportFrame = scroll.convert(scroll.bounds, to: host)
                let topGap = host.isFlipped ? viewportFrame.minY - navFrame.maxY : navFrame.minY - viewportFrame.maxY
                let bottomGap = host.isFlipped ? host.bounds.maxY - viewportFrame.maxY : viewportFrame.minY - host.bounds.minY
                XCTAssertEqual(topGap, ObservatoryAppearance.scrollViewportGutter, accuracy: 1)
                XCTAssertEqual(bottomGap, ObservatoryAppearance.scrollViewportGutter, accuracy: 1)
                XCTAssertEqual(viewportFrame.width, width - 44, accuracy: 1)
                let clip = scroll.contentView
                let document = try XCTUnwrap(scroll.documentView)
                let maxY = max(0, document.frame.height - clip.bounds.height)
                XCTAssertGreaterThan(maxY, 0)
                for offset in [CGFloat.zero, maxY / 2, maxY] {
                    clip.scroll(to: NSPoint(x: 0, y: offset))
                    scroll.reflectScrolledClipView(clip)
                    await refresh(host)
                    XCTAssertEqual(clip.bounds.minY, offset, accuracy: 1)
                    XCTAssertEqual(clip.bounds.minX, 0, accuracy: 1)
                    XCTAssertEqual(control.convert(control.bounds, to: host), navFrame)
                    XCTAssertEqual(scroll.convert(scroll.bounds, to: host), viewportFrame)
                }
                XCTAssertEqual(clip.bounds.maxY, document.frame.height, accuracy: 1,
                    "The real end remains reachable; a partial top row is ordinary viewport clipping")
                XCTAssertFalse(window.isVisible)
                XCTAssertTrue(NSApp.keyWindow === keyBefore)
                XCTAssertTrue(NSApp.mainWindow === mainBefore)
                XCTAssertEqual(fixture.coordinator.microphone.state, .closed)
                XCTAssertEqual(fixture.resources.counts.value.constructed, 0)
                XCTAssertEqual(fixture.inference.counts.value.loads, 0)
                XCTAssertEqual(fixture.inference.counts.value.decodes, 0)
                XCTAssertEqual(fixture.permissionCalls, 0)
                XCTAssertTrue(fixture.clipboard.calls.isEmpty)
            }
        }
    }

    @MainActor func testReviewNativeScrollerRepresentsOverflowAndReachesFinalLineAtBothWidths() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CLAVUNE_RUN_UI_HOST_FIXTURES"] == "1",
                          "Run only in the authorized offscreen macOS UI fixture pass")
        _ = NSApplication.shared
        let keyWindowBefore = NSApp.keyWindow
        let mainWindowBefore = NSApp.mainWindow
        let longText = (0..<80).map { "Paragraph \($0) ends in a complete sentence." }.joined(separator: "\n\n")
        for text in ["A short review stays readable without a scroll track.", longText] {
            let configuration = try AppLaunchConfiguration.parse(environment: [
                "CLAVUNE_QA_PROFILE": "overflow-" + String(UUID().uuidString.prefix(8)),
                "CLAVUNE_QA_FUNCTIONAL": "synthetic-v1",
            ])
            let fixture = try CoordinatorFixture(launchConfiguration: configuration,
                processUsageSnapshot: { nil }, configureEnvironment: { environment in
                    environment.chooseTranscriptToOpen = { _ in
                        URL(fileURLWithPath: "/synthetic-overflow-never-opened.txt")
                    }
                    environment.readTranscript = { _ in text }
                })
            fixture.coordinator.uiLanguage = .english
            fixture.coordinator.openTranscript()
            await waitForOperation(fixture)
            let reviewID = fixture.coordinator.session.id
            let sizing = QAWindowLayout.reviewSize(forUTF8Bytes: text.utf8.count)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: sizing.window),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let host = NSHostingView(rootView: DictationView(coordinator: fixture.coordinator))
            window.contentView = host
            await refresh(host)
            let editor = try XCTUnwrap(editableReviews(in: host).first)
            let scroll = try XCTUnwrap(editor.enclosingScrollView)
            for width: CGFloat in [560, 780] {
                window.setContentSize(NSSize(width: width, height: sizing.window))
                await refresh(host)
                let manager = try XCTUnwrap(editor.layoutManager)
                let container = try XCTUnwrap(editor.textContainer)
                manager.ensureLayout(for: container)
                scroll.tile()
                scroll.reflectScrolledClipView(scroll.contentView)
                XCTAssertTrue(try XCTUnwrap(editableReviews(in: host).first) === editor)
                XCTAssertEqual(scroll.bounds.height, sizing.editor, accuracy: 1)
                XCTAssertEqual(scroll.scrollerStyle, .legacy)
                XCTAssertEqual(scroll.scrollerKnobStyle, .light)
                XCTAssertTrue(scroll.autohidesScrollers)
                let scroller = try XCTUnwrap(scroll.verticalScroller)
                if text == longText {
                    XCTAssertGreaterThan(editor.bounds.height, scroll.contentView.bounds.height)
                    XCTAssertFalse(scroller.isHidden, "Real overflow needs a persistent native continuation cue")
                    XCTAssertGreaterThan(scroller.knobProportion, 0)
                    XCTAssertLessThan(scroller.knobProportion, 1)
                    let selection = editor.selectedRange()
                    let lastCharacter = NSRange(location: (text as NSString).length - 1, length: 1)
                    editor.scrollRangeToVisible(lastCharacter)
                    await refresh(host)
                    let glyphs = manager.glyphRange(forCharacterRange: lastCharacter, actualCharacterRange: nil)
                    let lastLine = manager.boundingRect(forGlyphRange: glyphs, in: container)
                        .offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
                    XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
                    XCTAssertGreaterThanOrEqual(editor.visibleRect.maxY + 1, lastLine.maxY,
                        "The final line must be reachable, not masked or discarded at the viewport edge")
                    XCTAssertLessThanOrEqual(editor.visibleRect.minY, lastLine.minY + 1,
                        "The viewport must include the top of the final line, not scroll entirely beyond it")
                    XCTAssertEqual(editor.selectedRange(), selection)
                } else {
                    XCTAssertTrue(scroller.isHidden, "Short text must not imply nonexistent continuation")
                }
                XCTAssertEqual(editor.string, text)
                XCTAssertEqual(fixture.coordinator.editedText, text)
                XCTAssertEqual(fixture.coordinator.session.id, reviewID)
            }
            XCTAssertFalse(window.isVisible)
            XCTAssertTrue(NSApp.keyWindow === keyWindowBefore)
            XCTAssertTrue(NSApp.mainWindow === mainWindowBefore)
            XCTAssertEqual(fixture.coordinator.microphone.state, .closed)
            XCTAssertEqual(fixture.resources.counts.value.constructed, 0)
            XCTAssertEqual(fixture.inference.counts.value.loads, 0)
            XCTAssertEqual(fixture.inference.counts.value.decodes, 0)
            XCTAssertEqual(fixture.permissionCalls, 0)
            XCTAssertTrue(fixture.clipboard.calls.isEmpty)
        }
    }

    @MainActor func testWidthAndLanguageChangesPreserveEditorUndoAndMarkedText() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CLAVUNE_RUN_UI_HOST_FIXTURES"] == "1",
                          "Run only in the authorized offscreen macOS UI fixture pass")
        _ = NSApplication.shared
        let keyWindowBefore = NSApp.keyWindow
        let configuration = try AppLaunchConfiguration.parse(environment: [
            "CLAVUNE_QA_PROFILE": "compact-" + String(UUID().uuidString.prefix(8)),
            "CLAVUNE_QA_FUNCTIONAL": "synthetic-v1",
        ])
        let originalText = "Review the outline before the next meeting."
        let fixture = try CoordinatorFixture(launchConfiguration: configuration,
            processUsageSnapshot: { nil }, configureEnvironment: { environment in
                environment.chooseTranscriptToOpen = { _ in
                    URL(fileURLWithPath: "/synthetic-compact-never-opened.txt")
                }
                environment.readTranscript = { _ in originalText }
            })
        fixture.coordinator.openTranscript()
        await waitForOperation(fixture)
        let reviewID = fixture.coordinator.session.id
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 360),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: DictationView(coordinator: fixture.coordinator))
        window.contentView = host
        await refresh(host)
        XCTAssertEqual(editableReviews(in: host).count, 1)
        let editor = try XCTUnwrap(editableReviews(in: host).first)
        XCTAssertTrue(window.makeFirstResponder(editor))
        let undo = try XCTUnwrap(editor.undoManager)
        undo.beginUndoGrouping()
        editor.insertText(" Updated.", replacementRange: NSRange(location: (editor.string as NSString).length, length: 0))
        undo.endUndoGrouping()
        let selection = editor.selectedRange()

        for language in UILanguage.allCases {
            fixture.coordinator.uiLanguage = language
            for width: CGFloat in [560, 780, 560] {
                window.setContentSize(NSSize(width: width, height: 360))
                await refresh(host)
                XCTAssertEqual(editableReviews(in: host).count, 1)
                XCTAssertTrue(try XCTUnwrap(editableReviews(in: host).first) === editor)
                XCTAssertTrue(editor.undoManager === undo)
                XCTAssertTrue(undo.canUndo)
                XCTAssertEqual(editor.selectedRange(), selection)
                XCTAssertEqual(fixture.coordinator.session.id, reviewID)
                XCTAssertEqual(fixture.coordinator.editedText, originalText + " Updated.")
            }
        }
        undo.undo()
        XCTAssertEqual(fixture.coordinator.editedText, originalText)
        let composition = " composition"
        editor.setMarkedText(composition,
            selectedRange: NSRange(location: (composition as NSString).length, length: 0),
            replacementRange: NSRange(location: (editor.string as NSString).length, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        window.setContentSize(NSSize(width: 780, height: 360))
        await refresh(host)
        XCTAssertTrue(try XCTUnwrap(editableReviews(in: host).first) === editor)
        XCTAssertTrue(editor.hasMarkedText(), "Responsive toolbar layout must not end editor composition")
        editor.unmarkText()
        XCTAssertEqual(fixture.coordinator.editedText, originalText + composition)
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(NSApp.keyWindow === keyWindowBefore)
        XCTAssertEqual(fixture.coordinator.microphone.state, .closed)
        XCTAssertEqual(fixture.resources.counts.value.constructed, 0)
        XCTAssertEqual(fixture.inference.counts.value.loads, 0)
        XCTAssertEqual(fixture.inference.counts.value.decodes, 0)
        XCTAssertEqual(fixture.permissionCalls, 0)
        XCTAssertTrue(fixture.clipboard.calls.isEmpty)
    }

    @MainActor func testAnotherHostEditWhileMarkedReplacesDraftAndClearsOnlyStaleUndo() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CLAVUNE_RUN_UI_HOST_FIXTURES"] == "1",
                          "Run only in the authorized offscreen macOS UI fixture pass")
        _ = NSApplication.shared
        let keyWindowBefore = NSApp.keyWindow
        let configuration = try AppLaunchConfiguration.parse(environment: [
            "CLAVUNE_QA_PROFILE": "marked-" + String(UUID().uuidString.prefix(8)),
            "CLAVUNE_QA_FUNCTIONAL": "synthetic-v1",
        ])
        let fixture = try CoordinatorFixture(launchConfiguration: configuration,
            processUsageSnapshot: { nil }, configureEnvironment: { environment in
                environment.chooseTranscriptToOpen = { _ in
                    URL(fileURLWithPath: "/synthetic-marked-two-hosts-never-opened.txt")
                }
                environment.readTranscript = { _ in "Shared review" }
            })
        fixture.coordinator.openTranscript()
        await waitForOperation(fixture)
        let reviewID = fixture.coordinator.session.id
        let firstWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
                                   styleMask: [.titled], backing: .buffered, defer: true)
        let secondWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 360),
                                    styleMask: [.titled], backing: .buffered, defer: true)
        firstWindow.isReleasedWhenClosed = false
        secondWindow.isReleasedWhenClosed = false
        defer { firstWindow.close(); secondWindow.close() }
        let firstHost = NSHostingView(rootView: DictationView(coordinator: fixture.coordinator))
        let secondHost = NSHostingView(rootView: DictationView(coordinator: fixture.coordinator,
                                                             isAuxiliaryPanel: true))
        firstWindow.contentView = firstHost
        secondWindow.contentView = secondHost
        await refresh(firstHost); await refresh(secondHost)
        let first = try XCTUnwrap(editableReviews(in: firstHost).first)
        let second = try XCTUnwrap(editableReviews(in: secondHost).first)
        XCTAssertTrue(firstWindow.makeFirstResponder(first))
        let firstUndo = try XCTUnwrap(first.undoManager)
        firstUndo.beginUndoGrouping()
        first.insertText(" local", replacementRange: NSRange(location: (first.string as NSString).length, length: 0))
        firstUndo.endUndoGrouping()
        await refresh(firstHost); await refresh(secondHost)
        XCTAssertTrue(firstUndo.canUndo)
        XCTAssertEqual(second.string, "Shared review local")

        // Establish each hidden window's responder before composition. The
        // subsequent edit must test a binding replacement, not a focus change.
        XCTAssertTrue(secondWindow.makeFirstResponder(second))
        first.setSelectedRange(NSRange(location: (first.string as NSString).length, length: 0))
        first.setMarkedText(" composition", selectedRange: NSRange(location: 12, length: 0),
                            replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(first.hasMarkedText(), "Establish real native composition before the external edit")
        let secondUndo = try XCTUnwrap(second.undoManager)
        secondUndo.beginUndoGrouping()
        second.insertText(" external", replacementRange: NSRange(location: (second.string as NSString).length, length: 0))
        secondUndo.endUndoGrouping()
        await refresh(firstHost); await refresh(secondHost)

        XCTAssertTrue(try XCTUnwrap(editableReviews(in: firstHost).first) === first)
        XCTAssertTrue(try XCTUnwrap(editableReviews(in: secondHost).first) === second)
        XCTAssertEqual(first.string, "Shared review local external")
        XCTAssertEqual(second.string, first.string)
        XCTAssertEqual(fixture.coordinator.editedText, first.string)
        XCTAssertFalse(first.hasMarkedText(), "A real external draft replacement must not be silently ignored")
        XCTAssertFalse(firstUndo.canUndo, "External replacement invalidates only stale local ranges")
        XCTAssertFalse(firstUndo.canRedo)
        XCTAssertTrue(secondUndo.canUndo, "The authoring host retains its native history")
        secondUndo.undo()
        await refresh(firstHost); await refresh(secondHost)
        XCTAssertEqual(first.string, "Shared review local")
        XCTAssertEqual(fixture.coordinator.editedText, "Shared review local")
        XCTAssertFalse(firstUndo.canUndo)
        // Invalidation must not disable later user Undo or leave the old
        // composition's coalescing/selection ranges attached to a fresh edit.
        XCTAssertTrue(firstWindow.makeFirstResponder(first))
        first.setSelectedRange(NSRange(location: (first.string as NSString).length, length: 0))
        let selectionBeforeFreshEdit = first.selectedRange()
        firstUndo.beginUndoGrouping()
        first.insertText(" fresh", replacementRange: selectionBeforeFreshEdit)
        firstUndo.endUndoGrouping()
        let selectionAfterFreshEdit = first.selectedRange()
        XCTAssertTrue(firstUndo.canUndo)
        firstUndo.undo()
        await refresh(firstHost); await refresh(secondHost)
        XCTAssertEqual(first.string, "Shared review local")
        XCTAssertEqual(fixture.coordinator.editedText, "Shared review local")
        XCTAssertEqual(first.selectedRange(), selectionBeforeFreshEdit)
        XCTAssertTrue(firstUndo.canRedo)
        firstUndo.redo()
        await refresh(firstHost); await refresh(secondHost)
        XCTAssertEqual(first.string, "Shared review local fresh")
        XCTAssertEqual(fixture.coordinator.editedText, "Shared review local fresh")
        XCTAssertEqual(first.selectedRange(), selectionAfterFreshEdit)
        XCTAssertEqual(fixture.coordinator.session.id, reviewID)
        XCTAssertFalse(firstWindow.isVisible); XCTAssertFalse(secondWindow.isVisible)
        XCTAssertTrue(NSApp.keyWindow === keyWindowBefore)
        XCTAssertEqual(fixture.coordinator.microphone.state, .closed)
        XCTAssertEqual(fixture.resources.counts.value.constructed, 0)
        XCTAssertEqual(fixture.inference.counts.value.loads, 0)
        XCTAssertEqual(fixture.inference.counts.value.decodes, 0)
        XCTAssertEqual(fixture.permissionCalls, 0)
        XCTAssertTrue(fixture.clipboard.calls.isEmpty)
    }
}
