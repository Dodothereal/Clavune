import AppKit
import ClavuneCore
import QuartzCore
import SwiftUI

/// App-local, writable presentation seam for isolated static renders. This can
/// only strengthen the OS preference; it never changes system accessibility.
private struct ObservatoryForceReducedMotionKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var observatoryForceReducedMotion: Bool {
        get { self[ObservatoryForceReducedMotionKey.self] }
        set { self[ObservatoryForceReducedMotionKey.self] = newValue }
    }
}

/// The accepted Observatory's neutral ink, fine-rule, and hover grammar.
/// This is intentionally local to controls; it does not select a product mode.
private enum ObservatoryControlInk {
    static let canvas = NSColor(srgbRed: 11 / 255, green: 11 / 255, blue: 11 / 255, alpha: 1)
    static let surface = NSColor(srgbRed: 18 / 255, green: 18 / 255, blue: 18 / 255, alpha: 1)
    static let hover = NSColor(srgbRed: 29 / 255, green: 29 / 255, blue: 29 / 255, alpha: 1)
    static let pressed = NSColor(srgbRed: 42 / 255, green: 42 / 255, blue: 42 / 255, alpha: 1)
    static let ink = NSColor(srgbRed: 238 / 255, green: 238 / 255, blue: 238 / 255, alpha: 1)
    static let muted = NSColor(srgbRed: 166 / 255, green: 166 / 255, blue: 166 / 255, alpha: 1)
    static let rule = NSColor(srgbRed: 41 / 255, green: 41 / 255, blue: 41 / 255, alpha: 1)
    static let controlBorder = NSColor(srgbRed: 56 / 255, green: 56 / 255, blue: 56 / 255, alpha: 1)
    static let warning = NSColor(srgbRed: 225 / 255, green: 178 / 255, blue: 119 / 255, alpha: 1)
}

/// Four visual weights for the *existing* actions. Button still owns keyboard,
/// disabled, and accessibility semantics; this style never performs an action.
struct ObservatoryActionStyle: ButtonStyle {
    enum Role: Equatable { case primary, secondary, quiet, danger }
    let role: Role

    func makeBody(configuration: Configuration) -> some View {
        Appearance(configuration: configuration, role: role)
    }

    private struct Appearance: View {
        let configuration: ButtonStyle.Configuration
        let role: Role
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused
        @State private var hovered = false

        private var fill: Color {
            if !isEnabled { return role == .quiet ? .clear : Color(nsColor: ObservatoryControlInk.surface) }
            switch role {
            case .primary:
                if configuration.isPressed { return Color(nsColor: .init(srgbRed: 192 / 255, green: 192 / 255, blue: 192 / 255, alpha: 1)) }
                return hovered ? .white : Color(nsColor: ObservatoryControlInk.ink)
            case .secondary, .quiet:
                if configuration.isPressed { return Color(nsColor: ObservatoryControlInk.pressed) }
                return hovered ? Color(nsColor: ObservatoryControlInk.hover)
                               : (role == .secondary ? Color(nsColor: ObservatoryControlInk.surface) : .clear)
            case .danger:
                if configuration.isPressed { return Color(red: 55 / 255, green: 38 / 255, blue: 29 / 255) }
                return hovered ? Color(red: 43 / 255, green: 30 / 255, blue: 24 / 255)
                               : Color(red: 29 / 255, green: 21 / 255, blue: 18 / 255)
            }
        }
        private var foreground: Color {
            if !isEnabled { return Color(nsColor: ObservatoryControlInk.muted).opacity(0.6) }
            switch role {
            case .primary: return Color(nsColor: ObservatoryControlInk.canvas)
            case .secondary, .quiet: return Color(nsColor: ObservatoryControlInk.ink)
            case .danger: return Color(nsColor: ObservatoryControlInk.warning)
            }
        }
        private var border: Color {
            if !isEnabled { return role == .quiet ? .clear : Color(nsColor: ObservatoryControlInk.rule).opacity(0.5) }
            switch role {
            case .primary: return Color(nsColor: ObservatoryControlInk.ink)
            case .secondary: return Color(nsColor: ObservatoryControlInk.controlBorder)
            case .quiet: return .clear
            case .danger: return Color(nsColor: ObservatoryControlInk.warning).opacity(0.55)
            }
        }

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: role == .primary ? .medium : .regular))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(foreground)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(minHeight: ObservatoryAppearance.controlHeight)
                .background(fill, in: RoundedRectangle(cornerRadius: 4))
                .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(border, lineWidth: 1) }
                .overlay {
                    if isEnabled && isFocused {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color(nsColor: ObservatoryControlInk.ink), lineWidth: 2)
                            .padding(2)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 4))
                .onHover { hovered = $0 }
                // Hover and press respond immediately, including under Reduce Motion.
        }
    }
}

/// A compact label/value row. The native Menu keeps keyboard and VoiceOver
/// behavior; its trigger shares the same focus/hover grammar as other actions.
struct ObservatorySettingChoice<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    var fieldWidth: CGFloat = ObservatoryAppearance.fieldWidth
    @Environment(\.isEnabled) private var isEnabled

    private var selectedTitle: String {
        options.first(where: { $0.value == selection })?.title ?? title
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(ObservatoryAppearance.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                ForEach(options.indices, id: \.self) { index in
                    let option = options[index]
                    Button {
                        selection = option.value
                    } label: {
                        if selection == option.value {
                            Label(option.title, systemImage: "checkmark")
                        } else {
                            Text(option.title)
                        }
                    }
                }
            } label: {
                HStack(alignment: .center, spacing: 8) {
                    Text(selectedTitle)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .medium))
                        .accessibilityHidden(true)
                }
                .foregroundStyle(isEnabled ? ObservatoryAppearance.ink : ObservatoryAppearance.muted)
                .frame(width: fieldWidth - 20, alignment: .leading)
            }
            .menuStyle(.button)
            .buttonStyle(ObservatoryActionStyle(role: .secondary))
            .menuIndicator(.hidden)
            .accessibilityLabel(title)
            .accessibilityValue(selectedTitle)
            .help(selectedTitle)
        }
        .frame(minHeight: ObservatoryAppearance.settingRowHeight)
    }
}

/// A drawn switch retains its existing binding and disabled gates. The explicit
/// On/Off value complements position, and the shared button style provides focus ink.
struct ObservatoryLedgerToggleStyle: ToggleStyle {
    let title: String
    let onLabel: String
    let offLabel: String
    var fieldWidth: CGFloat = ObservatoryAppearance.fieldWidth

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 16) {
            configuration.label
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { configuration.isOn.toggle() } label: {
                HStack(spacing: 10) {
                    ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                        Capsule()
                            .fill(configuration.isOn
                                ? ObservatoryAppearance.ink : ObservatoryAppearance.rule)
                            .frame(width: 30, height: 16)
                        Circle()
                            .fill(configuration.isOn
                                ? ObservatoryAppearance.canvas : ObservatoryAppearance.muted)
                            .frame(width: 12, height: 12)
                            .padding(2)
                    }
                    .accessibilityHidden(true)
                    Text(configuration.isOn ? onLabel : offLabel)
                        .foregroundStyle(ObservatoryAppearance.muted)
                    Spacer(minLength: 0)
                }
                .frame(width: fieldWidth - 20, alignment: .leading)
            }
            .buttonStyle(ObservatoryActionStyle(role: .quiet))
            .accessibilityLabel(title)
            .accessibilityValue(configuration.isOn ? onLabel : offLabel)
        }
        .frame(minHeight: ObservatoryAppearance.settingRowHeight)
    }
}

/// Drop-in visual replacement for LocalizedNavigationSegments. The native
/// segmented control retains AppKit keyboard/AX behavior and a host window for
/// committing marked text *before* a hidden section replaces the editor.
struct ObservatoryNavigationSegments: NSViewRepresentable {
    @Binding var settingsVisible: Bool
    @Binding var statisticsVisible: Bool
    let accessibilityTitle: String
    let dictationTitle: String
    let settingsTitle: String
    let statisticsTitle: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.observatoryForceReducedMotion) private var forceReducedMotion

    init(settingsVisible: Binding<Bool>, statisticsVisible: Binding<Bool> = .constant(false),
         accessibilityTitle: String, dictationTitle: String, settingsTitle: String,
         statisticsTitle: String? = nil) {
        _settingsVisible = settingsVisible
        _statisticsVisible = statisticsVisible
        self.accessibilityTitle = accessibilityTitle
        self.dictationTitle = dictationTitle
        self.settingsTitle = settingsTitle
        self.statisticsTitle = statisticsTitle
    }

    private var labels: [String] {
        [dictationTitle, settingsTitle] + (statisticsTitle.map { [$0] } ?? [])
    }
    private var selectedIndex: Int {
        settingsVisible ? (statisticsTitle != nil && statisticsVisible ? 2 : 1) : 0
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> InkSegmentedControl {
        let control = InkSegmentedControl(labels: labels, trackingMode: .selectOne,
                                          target: context.coordinator,
                                          action: #selector(Coordinator.selectionChanged(_:)))
        control.focusRingType = .none // The ink control draws its own restrained focus cue.
        control.segmentDistribution = .fillEqually
        control.localizedAccessibilityTitle = accessibilityTitle
        control.reducedMotion = reduceMotion || forceReducedMotion
        control.selectedSegment = selectedIndex
        control.moveUnderline(animated: false)
        return control
    }

    func updateNSView(_ control: InkSegmentedControl, context: Context) {
        // The Statistics binding can synchronously publish while an action is
        // still setting both navigation bindings. Reconcile to the admitted
        // native choice until that action completes, not the intermediate one.
        let effectiveIndex = context.coordinator.admittedSelectionIndex ?? selectedIndex
        let enteringHiddenSection = context.coordinator.previousIndex != effectiveIndex && effectiveIndex != 0
        context.coordinator.parent = self
        var redraw = false
        if control.segmentCount != labels.count {
            control.segmentCount = labels.count
            redraw = true
        }
        for (index, label) in labels.enumerated() {
            if control.label(forSegment: index) != label {
                control.setLabel(label, forSegment: index)
                redraw = true
            }
        }
        control.localizedAccessibilityTitle = accessibilityTitle
        control.reducedMotion = reduceMotion || forceReducedMotion
        let changed = control.selectedSegment != effectiveIndex
        if changed { control.selectedSegment = effectiveIndex }
        control.moveUnderline(animated: false)
        // AppCoordinator may publish high-rate capture progress. Never turn an
        // unchanged navigation update into a 10 Hz custom redraw.
        if redraw || changed { control.needsDisplay = true }
        if enteringHiddenSection, let window = control.window {
            _ = window.makeFirstResponder(control)
        }
        context.coordinator.previousIndex = effectiveIndex
    }

    static func dismantleNSView(_ control: InkSegmentedControl, coordinator: Coordinator) {
        control.target = nil
        control.action = nil
        control.tearDown()
    }

    @MainActor final class Coordinator: NSObject {
        var parent: ObservatoryNavigationSegments
        var previousIndex: Int
        var admittedSelectionIndex: Int?
        init(_ parent: ObservatoryNavigationSegments) {
            self.parent = parent
            previousIndex = parent.selectedIndex
        }

        @objc func selectionChanged(_ sender: NSSegmentedControl) {
            let index = sender.selectedSegment
            guard index >= 0, index < sender.segmentCount else { return }
            if index != 0, !parent.settingsVisible,
               let editor = sender.window?.firstResponder as? PlainTranscriptTextView,
               editor.hasMarkedText() {
                editor.unmarkText()
            }
            admittedSelectionIndex = index
            defer { admittedSelectionIndex = nil }
            // The marked-text commit can publish the review binding while the
            // SwiftUI tab state is still old. If that update briefly restores
            // the old native selectedSegment, keep this admitted user choice.
            if sender.selectedSegment != index { sender.selectedSegment = index }
            // Move the selected ink before changing SwiftUI state. A
            // synchronous updateNSView can then see the settled model frame
            // without snapping a just-started event animation to its end.
            (sender as? InkSegmentedControl)?.moveUnderline(animated: true)
            // Keyboard and AX actions do not pass through mouseDown. Their
            // selection may already equal the new binding by updateNSView;
            // repaint the selected text weight/color for this action only.
            sender.needsDisplay = true
            // The statistics binding is product-owned: it cancels an active
            // hotkey recorder before Settings is hidden by this transition.
            parent.statisticsVisible = index == 2
            parent.settingsVisible = index != 0
        }
    }
}

/// Draw only the ink/rule/underline surface; NSSegmentedControl still owns hit
/// testing, keyboard selection, and the selected-segment accessibility model.
final class InkSegmentedControl: NSSegmentedControl {
    var localizedAccessibilityTitle: String?
    var reducedMotion = false {
        didSet { if reducedMotion { underlineLayer.removeAllAnimations() } }
    }
    private let underlineLayer = CALayer()
    private let underlineAnimationKey = "clavune.selection"
    private var hoverSegment: Int?
    private var pressedSegment: Int?
    private var pointerArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: ObservatoryAppearance.navigationHeight)
    }
    override func accessibilityLabel() -> String? {
        localizedAccessibilityTitle ?? super.accessibilityLabel()
    }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { moveUnderline(animated: false, focused: true); needsDisplay = true }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        // AppKit has not changed window.firstResponder yet inside this call.
        if resigned { moveUnderline(animated: false, focused: false); needsDisplay = true }
        return resigned
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusRingType = .none
        wantsLayer = true
        installUnderlineIfNeeded()
        moveUnderline(animated: false)
    }
    override func layout() {
        super.layout()
        moveUnderline(animated: false)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerArea { removeTrackingArea(pointerArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .mouseMoved,
                                            .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        pointerArea = area
    }
    override func mouseEntered(with event: NSEvent) { updateHover(with: event) }
    override func mouseMoved(with event: NSEvent) { updateHover(with: event) }
    override func mouseExited(with event: NSEvent) {
        if hoverSegment != nil { hoverSegment = nil; needsDisplay = true }
    }
    override func mouseDown(with event: NSEvent) {
        pressedSegment = segment(at: convert(event.locationInWindow, from: nil))
        needsDisplay = true
        displayIfNeeded()
        super.mouseDown(with: event)
        pressedSegment = nil
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        ObservatoryControlInk.canvas.setFill()
        NSBezierPath.fill(bounds)
        guard segmentCount > 0, bounds.width > 0 else { return }
        let width = bounds.width / CGFloat(segmentCount)
        for index in 0..<segmentCount {
            let segment = NSRect(x: bounds.minX + CGFloat(index) * width,
                                 y: bounds.minY, width: width, height: bounds.height)
            if isEnabled && pressedSegment == index {
                ObservatoryControlInk.pressed.setFill(); NSBezierPath.fill(segment)
            } else if isEnabled && hoverSegment == index {
                ObservatoryControlInk.hover.setFill(); NSBezierPath.fill(segment)
            }
            let color: NSColor = !isEnabled ? ObservatoryControlInk.muted.withAlphaComponent(0.55)
                : index == selectedSegment ? ObservatoryControlInk.ink : ObservatoryControlInk.muted
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingTail
            let font = NSFont.systemFont(ofSize: 12, weight: index == selectedSegment ? .medium : .regular)
            let text = NSAttributedString(string: label(forSegment: index) ?? "",
                                          attributes: [.font: font, .foregroundColor: color,
                                                       .paragraphStyle: paragraph])
            text.draw(in: segment.insetBy(dx: 8, dy: (bounds.height - 20) / 2))
        }
        ObservatoryControlInk.rule.setFill()
        let ruleY = isFlipped ? bounds.maxY - 1 : bounds.minY
        NSBezierPath.fill(NSRect(x: bounds.minX, y: ruleY, width: bounds.width, height: 1))
    }

    func moveUnderline(animated: Bool, focused: Bool? = nil) {
        installUnderlineIfNeeded()
        guard let layer, segmentCount > 0, selectedSegment >= 0,
              selectedSegment < segmentCount, bounds.width > 0 else {
            underlineLayer.removeAnimation(forKey: underlineAnimationKey)
            underlineLayer.isHidden = true
            return
        }
        let width = bounds.width / CGFloat(segmentCount)
        // Keyboard focus thickens the existing selection rule instead of
        // drawing an unrelated mark above the tab.
        let thickness: CGFloat = (focused ?? (window?.firstResponder === self)) ? 3 : 2
        let layerY = layer.isGeometryFlipped ? bounds.height - thickness : 0
        let destination = CGRect(x: CGFloat(selectedSegment) * width + 8,
                                 y: layerY, width: max(0, width - 16), height: thickness)
        underlineLayer.isHidden = false
        if reducedMotion { underlineLayer.removeAllAnimations() }
        // Repeated SwiftUI updates and layout during an admitted action must
        // leave an already-running event animation alone.
        guard underlineLayer.frame != destination else { return }
        let startX = underlineLayer.presentation()?.position.x ?? underlineLayer.position.x
        // A new destination retires the prior animation even if its current
        // visual position is already too close to warrant another animation.
        underlineLayer.removeAnimation(forKey: underlineAnimationKey)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        underlineLayer.frame = destination
        CATransaction.commit()
        if animated && !reducedMotion && abs(startX - destination.midX) > 0.5 {
            let motion = CABasicAnimation(keyPath: "position.x")
            motion.fromValue = startX
            motion.toValue = destination.midX
            motion.duration = 0.14
            motion.timingFunction = CAMediaTimingFunction(name: .easeOut)
            underlineLayer.add(motion, forKey: underlineAnimationKey)
        }
    }

    func tearDown() {
        if let pointerArea { removeTrackingArea(pointerArea); self.pointerArea = nil }
        underlineLayer.removeAllAnimations()
        underlineLayer.removeFromSuperlayer()
    }
    private func installUnderlineIfNeeded() {
        guard underlineLayer.superlayer == nil, let layer else { return }
        underlineLayer.backgroundColor = ObservatoryControlInk.ink.cgColor
        underlineLayer.name = "clavune.navigation.underline"
        layer.addSublayer(underlineLayer)
    }
    private func segment(at point: NSPoint) -> Int? {
        guard bounds.contains(point), segmentCount > 0, bounds.width > 0 else { return nil }
        return min(segmentCount - 1,
                   max(0, Int((point.x - bounds.minX) / bounds.width * CGFloat(segmentCount))))
    }
    private func updateHover(with event: NSEvent) {
        let next = segment(at: convert(event.locationInWindow, from: nil))
        if next != hoverSegment { hoverSegment = next; needsDisplay = true }
    }
}
