import AppKit
import ClavuneCore
import SwiftUI

/// The comparison app has no transcript to fill an idle window. Keep that
/// state compact, then give the real editor and settings their working height.
enum QAWindowLayout {
    static let emptyStatisticsHeight: CGFloat = 200
    static let compactHeight: CGFloat = 200
    static let singleSourceStatisticsHeight: CGFloat = 420
    static let expandedHeight: CGFloat = 580

    /// Only the isolated comparison app sizes itself around a review. Three
    /// bounded viewports keep a short scripted result compact while retaining
    /// a useful native scrolling editor for a long transcript. The thresholds
    /// change the window only when text crosses a band, never per character.
    static func reviewSize(forUTF8Bytes bytes: Int) -> (window: CGFloat, editor: CGFloat) {
        if bytes <= 180 { return (360, ObservatoryAppearance.reviewEditorMinimumHeight(utf8ByteCount: bytes)) }
        if bytes <= 1_200 { return (440, ObservatoryAppearance.reviewEditorMinimumHeight(utf8ByteCount: bytes)) }
        return (580, ObservatoryAppearance.reviewEditorMinimumHeight(utf8ByteCount: bytes))
    }

    static func contentHeight(isQA: Bool, isAuxiliaryPanel: Bool,
                              settingsVisible: Bool, statisticsVisible: Bool,
                              statisticsPreview: Bool = false,
                              statisticsPreviewHasOneSource: Bool = false,
                              phase: SessionPhase, busy: Bool,
                              reviewUTF8Bytes: Int = 0) -> CGFloat? {
        guard isQA && !isAuxiliaryPanel else { return nil }
        if settingsVisible {
            if statisticsVisible {
                if !statisticsPreview { return emptyStatisticsHeight }
                return statisticsPreviewHasOneSource ? singleSourceStatisticsHeight : expandedHeight
            }
            return expandedHeight
        }
        if phase == .review { return reviewSize(forUTF8Bytes: reviewUTF8Bytes).window }
        return phase == .idle && !busy ? compactHeight : expandedHeight
    }
}

/// A leaf view uses its own window. It does not select another process/window,
/// change focus, or run a timer. A user's manual resize is left alone until the
/// content mode changes again.
@MainActor
struct QAAdaptiveWindowSize: NSViewRepresentable {
    let contentHeight: CGFloat
    var preferredWidth: CGFloat? = nil

    func makeNSView(context: Context) -> SizingView {
        SizingView(contentHeight: contentHeight, preferredWidth: preferredWidth)
    }
    func updateNSView(_ view: SizingView, context: Context) {
        view.request(contentHeight, preferredWidth: preferredWidth)
    }

    final class SizingView: NSView {
        private var contentHeight: CGFloat
        private var preferredWidth: CGFloat?
        private var lastAppliedHeight: CGFloat?
        private var lastAppliedWidth: CGFloat?
        private var applyScheduled = false

        init(contentHeight: CGFloat, preferredWidth: CGFloat? = nil) {
            self.contentHeight = contentHeight
            self.preferredWidth = preferredWidth
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleApply()
        }

        func request(_ height: CGFloat, preferredWidth width: CGFloat? = nil) {
            contentHeight = height
            preferredWidth = width
            if lastAppliedHeight != height || (width != nil && lastAppliedWidth != width) {
                scheduleApply()
            }
        }

        private func scheduleApply() {
            guard !applyScheduled else { return }
            applyScheduled = true
            // Wait for SwiftUI's new minimum height and main-window registration.
            // Multiple publications during one turn produce only one resize.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.applyScheduled = false
                self.applyIfNeeded()
            }
        }

        private func applyIfNeeded() {
            // SwiftUI's Window(id: "main") can restore its scene identifier
            // after the registration view sets "clavune.main". Both names
            // identify this QA main host; auxiliary panels are not mounted here.
            guard lastAppliedHeight != contentHeight ||
                    (preferredWidth != nil && lastAppliedWidth != preferredWidth), let window,
                  ["main", "clavune.main"].contains(window.identifier?.rawValue ?? "") else { return }
            let content = window.contentRect(forFrameRect: window.frame)
            let changeHeight = lastAppliedHeight != contentHeight && abs(content.height - contentHeight) > 1
            let changeWidth = preferredWidth.map {
                lastAppliedWidth != $0 && abs(content.width - $0) > 1
            } ?? false
            if changeHeight || changeWidth {
                var requestedContent = content
                if changeHeight { requestedContent.size.height = contentHeight }
                if changeWidth, let preferredWidth { requestedContent.size.width = preferredWidth }
                var frame = window.frame
                let top = frame.maxY
                let targetFrame = window.frameRect(forContentRect: requestedContent)
                frame.size = targetFrame.size
                frame.origin.y = top - frame.height
                if let visible = window.screen?.visibleFrame {
                    frame.origin.y = max(visible.minY, frame.origin.y)
                    frame.origin.x = min(frame.origin.x, visible.maxX - frame.width)
                }
                window.setFrame(frame, display: true, animate: false)
            }
            let updated = window.contentRect(forFrameRect: window.frame)
            if abs(updated.height - contentHeight) <= 1 { lastAppliedHeight = contentHeight }
            if let preferredWidth, abs(updated.width - preferredWidth) <= 1 {
                lastAppliedWidth = preferredWidth
            }
        }
    }
}
