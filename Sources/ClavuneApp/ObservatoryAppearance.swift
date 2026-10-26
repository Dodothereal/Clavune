import AppKit
import SwiftUI

/// The accepted Observatory's visual grammar adapted to an offline dictation
/// workbench. These values never carry benchmark data or alter app admission.
enum ObservatoryAppearance {
    static let canvas = Color(red: 11.0 / 255.0, green: 11.0 / 255.0, blue: 11.0 / 255.0)
    static let surface = Color(red: 18.0 / 255.0, green: 18.0 / 255.0, blue: 18.0 / 255.0)
    static let raised = Color(red: 27.0 / 255.0, green: 27.0 / 255.0, blue: 27.0 / 255.0)
    static let ink = Color(red: 238.0 / 255.0, green: 238.0 / 255.0, blue: 238.0 / 255.0)
    static let muted = Color(red: 166.0 / 255.0, green: 166.0 / 255.0, blue: 166.0 / 255.0)
    static let rule = Color(red: 41.0 / 255.0, green: 41.0 / 255.0, blue: 41.0 / 255.0)
    static let warning = Color(red: 235.0 / 255.0, green: 185.0 / 255.0, blue: 123.0 / 255.0)

    // Shared compact desktop rhythm; these values never change action admission.
    static let controlHeight: CGFloat = 32
    static let settingRowHeight: CGFloat = 32
    static let fieldWidth: CGFloat = 188
    static let settingsFieldWidth: CGFloat = 228
    static let settingsColumnWidth: CGFloat = 480
    static let scrollViewportGutter: CGFloat = 8
    static let settingsViewportGutter: CGFloat = scrollViewportGutter
    static let navigationHeight: CGFloat = 38

    /// Bounded content sizing, independent of QA window sizing. Byte bands are
    /// deliberately conservative for multilingual text; the native editor still scrolls.
    static func reviewEditorMinimumHeight(utf8ByteCount: Int) -> CGFloat {
        if utf8ByteCount <= 180 { return 96 }
        if utf8ByteCount <= 1_200 { return 180 }
        // Use the long-review canvas without crowding its original-text disclosure.
        return 336
    }

    static let editorBackground = NSColor(srgbRed: 18.0 / 255.0, green: 18.0 / 255.0,
                                          blue: 18.0 / 255.0, alpha: 1)
    static let editorInk = NSColor(srgbRed: 238.0 / 255.0, green: 238.0 / 255.0,
                                  blue: 238.0 / 255.0, alpha: 1)
}

/// Native tracing of the accepted v3 bracket/chevron mark. It is a visual
/// brand cue only; the app still reports its real microphone state in text.
struct ObservatoryMark: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x / 32,
                    y: rect.minY + rect.height * y / 32)
        }
        var p = Path()
        p.move(to: point(10, 4)); p.addLine(to: point(4, 4))
        p.addLine(to: point(4, 28)); p.addLine(to: point(10, 28))
        p.move(to: point(22, 4)); p.addLine(to: point(28, 4))
        p.addLine(to: point(28, 28)); p.addLine(to: point(22, 28))
        p.move(to: point(11, 11)); p.addLine(to: point(16, 16))
        p.addLine(to: point(11, 21))
        p.move(to: point(20, 11)); p.addLine(to: point(20, 21))
        return p
    }
}
