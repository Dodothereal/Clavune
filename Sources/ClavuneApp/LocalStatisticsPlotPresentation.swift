import Foundation

/// Presentation-only scale for already-aggregated measurements. It neither
/// reads events nor changes sample selection, means, period or export values.
struct LocalStatisticsPlotScale: Equatable, Sendable {
    enum Unit: Equatable, Sendable {
        case words, milliseconds, seconds, minutes, hours

        var secondsPerUnit: Double {
            switch self {
            case .words, .seconds: return 1
            case .milliseconds: return 0.001
            case .minutes: return 60
            case .hours: return 3_600
            }
        }

        func symbol(english: Bool) -> String {
            switch self {
            case .words: return english ? "words" : "Wörter"
            case .milliseconds: return "ms"
            case .seconds: return "s"
            case .minutes: return "min"
            case .hours: return "h"
            }
        }
    }

    let upperBound: Double
    let unit: Unit

    static func words(_ values: [Int?]) -> Self? {
        let valid = values.compactMap { $0 }.filter { $0 >= 0 }
        guard let maximum = valid.max() else { return nil }
        return Self(upperBound: niceUpperBound(Double(maximum)), unit: .words)
    }

    static func elapsedSeconds(_ values: [Double?]) -> Self? {
        let valid = values.compactMap { $0 }.filter { $0.isFinite && $0 >= 0 }
        guard let maximum = valid.max() else { return nil }
        let unit: Unit
        switch maximum {
        case 0: unit = .seconds
        case ..<1: unit = .milliseconds
        case ..<120: unit = .seconds
        case ..<7_200: unit = .minutes
        default: unit = .hours
        }
        return Self(upperBound: niceUpperBound(maximum / unit.secondsPerUnit), unit: unit)
    }

    /// Input remains words or source seconds; conversion is display-only.
    func proportion(for value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0,
              upperBound.isFinite, upperBound > 0 else { return nil }
        let displayed = value / unit.secondsPerUnit
        guard displayed.isFinite else { return nil }
        return min(1, max(0, displayed / upperBound))
    }

    func displayedValue(for value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        let displayed = value / unit.secondsPerUnit
        return displayed.isFinite ? displayed : nil
    }

    private static func niceUpperBound(_ maximum: Double) -> Double {
        guard maximum > 0 else { return 1 }
        let magnitude = pow(10.0, floor(log10(maximum)))
        // A subnormal power can underflow, and the next nice step can overflow.
        // An explicit finite maximum is more honest than an infinite/clipped axis.
        guard magnitude.isFinite, magnitude > 0 else { return maximum }
        for step in [1.0, 2.0, 5.0, 10.0] {
            let candidate = step * magnitude
            if candidate.isFinite && candidate >= maximum { return candidate }
        }
        return maximum
    }
}

/// Localized presentation copy is kept here to avoid changing shared language
/// keys while the shared-shell visual patch is developed independently.
struct LocalStatisticsPlotText {
    let english: Bool
    var locale: Locale { Locale(identifier: english ? "en_US" : "de_DE") }
    var previewProvenance: String {
        english ? "Preview data · no journal read" : "Vorschaudaten · kein Journal gelesen"
    }
    var durationMeaning: String {
        english ? "Elapsed time · not a performance score." : "Dauer · kein Leistungswert."
    }
    var durationHelp: String {
        english
            ? "Mean decode-service time including result extraction, excluding queue wait and UI. Different workloads are not a speed benchmark."
            : "Mittlere Dekodierdienst-Zeit einschließlich Ergebnisauswertung, ohne Warteschlange und Oberfläche. Unterschiedliche Aufgaben sind kein Geschwindigkeitsvergleich."
    }

    func scaleLabel(_ scale: LocalStatisticsPlotScale) -> String {
        let prefix = english ? "Scale" : "Skala"
        return "\(prefix) · 0–\(number(scale.upperBound, roundingUp: true)) \(scale.unit.symbol(english: english))"
    }

    /// Labels use the same display unit and concrete upper bound as the
    /// shared scale; never renormalize a source or imply elapsed-time quality.
    func axisEndpoints(_ scale: LocalStatisticsPlotScale) -> (lower: String, upper: String) {
        let unit = scale.unit.symbol(english: english)
        return (number(0) + " " + unit, number(scale.upperBound, roundingUp: true) + " " + unit)
    }

    func duration(_ seconds: Double?, on scale: LocalStatisticsPlotScale?) -> String? {
        guard let scale, let value = scale.displayedValue(for: seconds) else { return nil }
        return number(value) + " " + scale.unit.symbol(english: english)
    }

    func count(_ value: Int?, compact: Bool = false) -> String? {
        guard let value, value >= 0 else { return nil }
        if compact && value >= 1_000_000_000 { return "≈" + number(Double(value)) }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    func samples(observed: Int, unknown: Int, isDuration: Bool) -> String {
        let measured: String
        if english {
            measured = isDuration ? "Timed completed sessions" : "Completed sessions with a word count"
        } else {
            measured = isDuration ? "Abschlüsse mit Zeitmessung" : "Abschlüsse mit Wortzählung"
        }
        return "\(measured): \(observed); \(english ? "unknown" : "unbekannt"): \(unknown)"
    }

    private func number(_ value: Double, roundingUp: Bool = false) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = value != 0 && (value < 0.001 || value >= 1_000_000_000)
            ? .scientific : .decimal
        formatter.usesGroupingSeparator = true
        formatter.usesSignificantDigits = true
        formatter.minimumSignificantDigits = 1
        formatter.maximumSignificantDigits = 4
        if roundingUp { formatter.roundingMode = .ceiling }
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
