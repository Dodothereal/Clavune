import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import ClavuneApp
@testable import ClavuneCore

/// Synthetic presentation contracts. Numerical cases are pure; the explicitly
/// opt-in layout case mounts only inert geometry probes in a hidden host. No
/// disk loader, export, microphone, permissions, clipboard or coordinator is used.
final class LocalStatisticsPlotPresentationTests: XCTestCase {
    func testWordSourcesShareConcreteRoundedBound() throws {
        let scale = try XCTUnwrap(LocalStatisticsPlotScale.words([90, 40]))
        XCTAssertEqual(scale.unit, .words)
        XCTAssertEqual(scale.upperBound, 100)
        XCTAssertEqual(try XCTUnwrap(scale.proportion(for: 90)), 0.9, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(scale.proportion(for: 40)), 0.4, accuracy: 1e-12)
        XCTAssertEqual(LocalStatisticsPlotText(english: true).scaleLabel(scale), "Scale · 0–100 words")
        XCTAssertEqual(LocalStatisticsPlotText(english: false).scaleLabel(scale), "Skala · 0–100 Wörter")
    }

    func testDurationScaleIsElapsedSecondsNotPercentOrDesirability() throws {
        let scale = try XCTUnwrap(LocalStatisticsPlotScale.elapsedSeconds([2.4, 3.1]))
        let text = LocalStatisticsPlotText(english: true)
        XCTAssertEqual(scale.unit, .seconds)
        XCTAssertEqual(scale.upperBound, 5)
        XCTAssertEqual(try XCTUnwrap(scale.proportion(for: 2.4)), 0.48, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(scale.proportion(for: 3.1)), 0.62, accuracy: 1e-12)
        XCTAssertEqual(text.scaleLabel(scale), "Scale · 0–5 s")
        XCTAssertEqual(text.duration(2.4, on: scale), "2.4 s")
        XCTAssertTrue(text.durationMeaning.contains("not a performance score"))
        XCTAssertTrue(text.durationHelp.contains("excluding queue wait and UI"))
    }

    func testDurationAxisEndpointsUseTheExistingCommonBoundAndUnit() throws {
        let cases: [([Double?], String, String)] = [
            ([2.4, 3.1], "0 s", "5 s"),
            ([0, 0], "0 s", "1 s"),
            ([0.004, 0.012], "0 ms", "20 ms"),
            ([125, 360], "0 min", "10 min"),
            ([7_200, 10_000], "0 h", "5 h"),
        ]
        let text = LocalStatisticsPlotText(english: true)
        for (values, lower, upper) in cases {
            let scale = try XCTUnwrap(LocalStatisticsPlotScale.elapsedSeconds(values))
            let before = scale
            let endpoints = text.axisEndpoints(scale)
            XCTAssertEqual(endpoints.lower, lower)
            XCTAssertEqual(endpoints.upper, upper)
            XCTAssertTrue(text.scaleLabel(scale).hasSuffix(upper))
            XCTAssertEqual(scale, before, "Axis labels must not recompute or mutate the shared scale")
        }
    }

    func testDurationAxisEndpointsLocalizeWithoutLosingSmallValuesOrUnits() throws {
        let scale = try XCTUnwrap(LocalStatisticsPlotScale.elapsedSeconds([0.00004]))
        let english = LocalStatisticsPlotText(english: true).axisEndpoints(scale)
        let german = LocalStatisticsPlotText(english: false).axisEndpoints(scale)
        XCTAssertEqual(english.lower, "0 ms")
        XCTAssertEqual(english.upper, "0.05 ms")
        XCTAssertEqual(german.lower, "0 ms")
        XCTAssertEqual(german.upper, "0,05 ms")
        let words = try XCTUnwrap(LocalStatisticsPlotScale.words([90, 40]))
        XCTAssertEqual(LocalStatisticsPlotText(english: false).axisEndpoints(words).upper, "100 Wörter")
    }

    func testMissingAndInvalidValuesNeverBecomeZeroObservations() {
        XCTAssertNil(LocalStatisticsPlotScale.words([nil, -1]))
        XCTAssertNil(LocalStatisticsPlotScale.elapsedSeconds([nil, .nan, .infinity, -.infinity, -1]))
        let scale = LocalStatisticsPlotScale.elapsedSeconds([2, nil])
        XCTAssertEqual(scale?.upperBound, 2)
        let invalid: [Double?] = [nil, .nan, .infinity, -.infinity, -1]
        for value in invalid {
            XCTAssertNil(scale?.proportion(for: value))
            XCTAssertNil(scale?.displayedValue(for: value))
            XCTAssertNil(LocalStatisticsPlotText(english: true).duration(value, on: scale))
        }
        XCTAssertNil(LocalStatisticsPlotText(english: true).count(nil))
        XCTAssertNil(LocalStatisticsPlotText(english: true).count(-1))
    }

    func testMeasuredZeroHasAnExplicitFiniteScaleAndMarkerPosition() throws {
        let words = try XCTUnwrap(LocalStatisticsPlotScale.words([0, nil]))
        let duration = try XCTUnwrap(LocalStatisticsPlotScale.elapsedSeconds([0, 0]))
        XCTAssertEqual(words.upperBound, 1)
        XCTAssertEqual(duration.upperBound, 1)
        XCTAssertEqual(duration.unit, .seconds)
        XCTAssertEqual(words.proportion(for: 0), 0)
        XCTAssertEqual(duration.proportion(for: 0), 0)
        XCTAssertNil(words.proportion(for: nil))
        XCTAssertEqual(LocalStatisticsPlotText(english: true).duration(0, on: duration), "0 s")
    }

    func testDisplayUnitConversionDoesNotChangeRelativeGeometry() throws {
        let short = try XCTUnwrap(LocalStatisticsPlotScale.elapsedSeconds([0.004, 0.012]))
        XCTAssertEqual(short.unit, .milliseconds)
        XCTAssertEqual(short.upperBound, 20)
        XCTAssertEqual(try XCTUnwrap(short.proportion(for: 0.004)), 0.2, accuracy: 1e-12)
        XCTAssertEqual(LocalStatisticsPlotText(english: true).duration(0.004, on: short), "4 ms")
        let long = try XCTUnwrap(LocalStatisticsPlotScale.elapsedSeconds([125, 360]))
        XCTAssertEqual(long.unit, .minutes)
        XCTAssertEqual(long.upperBound, 10)
        XCTAssertEqual(try XCTUnwrap(long.proportion(for: 360)), 0.6, accuracy: 1e-12)
        XCTAssertEqual(LocalStatisticsPlotText(english: true).duration(360, on: long), "6 min")
    }

    func testUnitBoundariesAreChosenOnceForTheCommonScale() throws {
        let cases: [(Double, LocalStatisticsPlotScale.Unit)] = [
            (0, .seconds), (0.999, .milliseconds), (1, .seconds),
            (119.999, .seconds), (120, .minutes), (7_199, .minutes), (7_200, .hours)
        ]
        for (maximum, unit) in cases {
            let scale = try XCTUnwrap(LocalStatisticsPlotScale.elapsedSeconds([maximum / 2, maximum]))
            XCTAssertEqual(scale.unit, unit, "Maximum \(maximum)")
            XCTAssertGreaterThanOrEqual(scale.upperBound, maximum / unit.secondsPerUnit)
        }
    }

    func testNiceBoundaryNeverRoundsBelowTheMaximum() throws {
        let cases: [(Double, Double)] = [
            (1, 1), (Double(1).nextUp, 2), (2, 2), (Double(2).nextUp, 5),
            (5, 5), (Double(5).nextUp, 10), (10, 10), (Double(10).nextUp, 20)
        ]
        for (maximum, expected) in cases {
            let scale = try XCTUnwrap(LocalStatisticsPlotScale.elapsedSeconds([maximum]))
            XCTAssertEqual(scale.upperBound, expected)
            XCTAssertGreaterThanOrEqual(scale.upperBound, maximum)
            XCTAssertLessThanOrEqual(try XCTUnwrap(scale.proportion(for: maximum)), 1)
        }
    }

    func testExtremesRemainFiniteAndDoNotClampToAnInventedCap() throws {
        let huge = try XCTUnwrap(LocalStatisticsPlotScale.elapsedSeconds([Double.greatestFiniteMagnitude]))
        let tiny = try XCTUnwrap(LocalStatisticsPlotScale.elapsedSeconds([Double.leastNonzeroMagnitude]))
        let words = try XCTUnwrap(LocalStatisticsPlotScale.words([Int.max]))
        for scale in [huge, tiny, words] {
            XCTAssertTrue(scale.upperBound.isFinite)
            XCTAssertGreaterThan(scale.upperBound, 0)
        }
        XCTAssertGreaterThanOrEqual(huge.upperBound, Double.greatestFiniteMagnitude / 3_600)
        XCTAssertGreaterThanOrEqual(words.upperBound, Double(Int.max))
        XCTAssertGreaterThan(try XCTUnwrap(tiny.proportion(for: Double.leastNonzeroMagnitude)), 0)
        let text = LocalStatisticsPlotText(english: true)
        let tinyLabel = try XCTUnwrap(text.duration(Double.leastNonzeroMagnitude, on: tiny))
        XCTAssertNotEqual(tinyLabel, "0 ms")
        XCTAssertFalse(tinyLabel.lowercased().contains("nan"))
        XCTAssertFalse(text.scaleLabel(huge).lowercased().contains("inf"))
        XCTAssertTrue(try XCTUnwrap(text.count(Int.max, compact: true)).hasPrefix("≈"))
        XCTAssertEqual(try XCTUnwrap(text.count(Int.max)).filter(\.isNumber), String(Int.max))
    }

    func testProportionsAreFiniteMonotoneAndSourceOrderIndependent() throws {
        let values: [Double?] = [0, 0.25, 2.4, 3.1, 99]
        let scale = try XCTUnwrap(LocalStatisticsPlotScale.elapsedSeconds(values))
        XCTAssertEqual(scale, LocalStatisticsPlotScale.elapsedSeconds(Array(values.reversed())))
        var previous = -1.0
        for value in values {
            let next = try XCTUnwrap(scale.proportion(for: value))
            XCTAssertTrue(next.isFinite)
            XCTAssertGreaterThanOrEqual(next, previous)
            XCTAssertGreaterThanOrEqual(next, 0)
            XCTAssertLessThanOrEqual(next, 1)
            previous = next
        }
    }

    func testBothLanguagesHaveUnitsAndMetricSpecificSampleCounts() throws {
        let scale = try XCTUnwrap(LocalStatisticsPlotScale.elapsedSeconds([2.4]))
        let en = LocalStatisticsPlotText(english: true)
        let de = LocalStatisticsPlotText(english: false)
        XCTAssertEqual(de.duration(2.4, on: scale), "2,4 s")
        XCTAssertNotEqual(en.durationMeaning, de.durationMeaning)
        XCTAssertEqual(en.previewProvenance, "Preview data · no journal read")
        XCTAssertEqual(de.previewProvenance, "Vorschaudaten · kein Journal gelesen")
        XCTAssertTrue(en.samples(observed: 1, unknown: 2, isDuration: true).contains("Timed completed sessions: 1"))
        XCTAssertTrue(en.samples(observed: 1, unknown: 2, isDuration: false).contains("word count: 1"))
        XCTAssertTrue(de.samples(observed: 1, unknown: 2, isDuration: true).contains("unbekannt: 2"))
    }

    func testExistingSyntheticAggregateIsUnmodifiedByPresentation() async throws {
        let period = try LocalStatisticsPeriod.last7Days.interval(endingAt: LocalStatisticsSyntheticPreview.referenceTime)
        let result = try await LocalStatisticsSyntheticPreview.load(period)
        let before = result
        let microphone = result.report.microphone
        let file = result.report.audioFile
        let words = LocalStatisticsPlotScale.words([
            microphone.recognizedWordsOnCompleted.sum, file.recognizedWordsOnCompleted.sum
        ])
        let elapsed = LocalStatisticsPlotScale.elapsedSeconds([
            microphone.decodeServiceSecondsOnCompleted.mean, file.decodeServiceSecondsOnCompleted.mean
        ])
        XCTAssertEqual(words?.upperBound, 100)
        XCTAssertEqual(elapsed?.upperBound, 5)
        XCTAssertEqual(result, before)
        XCTAssertEqual(microphone.recognizedWordsOnCompleted.sum, 90)
        XCTAssertEqual(file.recognizedWordsOnCompleted.sum, 40)
        XCTAssertEqual(microphone.recognizedWordsOnCompleted.observed, 1)
        XCTAssertEqual(microphone.decodeServiceSecondsOnCompleted.observed, 1)
        XCTAssertEqual(result.diagnostics.readFiles, 0)
    }

    @MainActor func testPairedSourceRowsAlignAtWideWidthsAndKeepCompactBoundary() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CLAVUNE_RUN_UI_HOST_FIXTURES"] == "1",
                          "Run only in the authorized offscreen macOS UI fixture pass")
        _ = NSApplication.shared
        let keyWindowBefore = NSApp.keyWindow
        let mainWindowBefore = NSApp.mainWindow
        // 560/780-point windows have 44 points of horizontal shell padding.
        // The intervening cases straddle two 300-point cells + a 20-point gap.
        let widths: [CGFloat] = [516, 619, 620, 736]
        // Endpoints make duration taller; unknown/wrapped text may instead
        // make either cell taller. A row must use actual height, not a spacer.
        let heights: [(CGFloat, CGFloat)] = [(24, 42), (62, 42), (24, 66)]
        for (wordHeight, durationHeight) in heights {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 736, height: 400),
                                  styleMask: [.titled], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let host = NSHostingView(rootView: StatisticsPairLayoutFixture(
                wordHeight: wordHeight, durationHeight: durationHeight))
            window.contentView = host
            for width in widths {
                window.setContentSize(NSSize(width: width, height: 400))
                host.layoutSubtreeIfNeeded()
                let settled = expectation(description: "statistics pair layout turn")
                DispatchQueue.main.async { settled.fulfill() }
                await fulfillment(of: [settled], timeout: 2)
                host.layoutSubtreeIfNeeded()
                let probes = statisticsLayoutProbes(in: host)
                XCTAssertEqual(probes.count, 5, "Only the selected layout may be mounted")
                guard probes.count == 5 else { continue }
                let paired = width >= 620
                let prefix = paired ? "paired" : "compact"
                let frames = Dictionary(uniqueKeysWithValues: probes.map { probe in
                    (probe.probeName, probe.convert(probe.bounds, to: host))
                })
                XCTAssertEqual(Set(frames.keys), Set([
                    prefix + ".words.microphone", prefix + ".duration.microphone",
                    prefix + ".words.file", prefix + ".duration.file", prefix + ".duration.caption"
                ]))
                func frame(_ name: String) throws -> NSRect { try XCTUnwrap(frames[prefix + "." + name]) }
                func top(_ rect: NSRect) -> CGFloat {
                    host.isFlipped ? rect.minY : host.bounds.maxY - rect.maxY
                }
                let wordsMicrophone = try frame("words.microphone")
                let durationMicrophone = try frame("duration.microphone")
                let wordsFile = try frame("words.file")
                let durationFile = try frame("duration.file")
                let durationCaption = try frame("duration.caption")
                XCTAssertEqual(durationCaption.minX, durationFile.minX, accuracy: 0.5,
                               "The elapsed-time qualification must start at the time column, not the word column")
                XCTAssertEqual(durationCaption.width, durationFile.width, accuracy: 0.5)
                XCTAssertEqual(wordsMicrophone.height, wordHeight, accuracy: 0.5)
                XCTAssertEqual(durationMicrophone.height, durationHeight, accuracy: 0.5)
                if paired {
                    XCTAssertEqual(top(wordsMicrophone), top(durationMicrophone), accuracy: 0.5)
                    XCTAssertEqual(top(wordsFile), top(durationFile), accuracy: 0.5)
                    XCTAssertEqual(top(wordsFile) - top(wordsMicrophone),
                                   max(wordHeight, durationHeight) + 8, accuracy: 0.5)
                    XCTAssertEqual(wordsMicrophone.width, (width - 20) / 2, accuracy: 0.5)
                    XCTAssertEqual(durationMicrophone.width, wordsMicrophone.width, accuracy: 0.5)
                    XCTAssertEqual(durationMicrophone.minX - wordsMicrophone.maxX, 20, accuracy: 0.5)
                    XCTAssertEqual(top(durationCaption) - top(durationFile),
                                   max(wordHeight, durationHeight) + 8, accuracy: 0.5)
                } else {
                    XCTAssertEqual(wordsMicrophone.width, width, accuracy: 0.5)
                    XCTAssertEqual(top(wordsFile) - top(wordsMicrophone), wordHeight + 8, accuracy: 0.5)
                    XCTAssertEqual(top(durationMicrophone) - top(wordsFile), wordHeight + 14, accuracy: 0.5)
                    XCTAssertEqual(top(durationFile) - top(durationMicrophone), durationHeight + 8, accuracy: 0.5)
                    XCTAssertEqual(top(durationCaption) - top(durationFile), durationHeight + 8, accuracy: 0.5)
                }
                XCTAssertFalse(window.isVisible)
                XCTAssertFalse(window.isKeyWindow)
                XCTAssertFalse(window.isMainWindow)
                XCTAssertTrue(NSApp.keyWindow === keyWindowBefore)
                XCTAssertTrue(NSApp.mainWindow === mainWindowBefore)
            }
        }
    }

    @MainActor private func statisticsLayoutProbes(in view: NSView) -> [StatisticsLayoutProbeView] {
        (view as? StatisticsLayoutProbeView).map { [$0] } ??
            view.subviews.flatMap { statisticsLayoutProbes(in: $0) }
    }

    /// Exercises the production pair, with deliberately unequal synthetic cell
    /// heights. Page wiring is separately guarded; this is not a page pixel test.
    private struct StatisticsPairLayoutFixture: View {
        let wordHeight: CGFloat
        let durationHeight: CGFloat

        var body: some View {
            ViewThatFits(in: .horizontal) {
                VStack(alignment: .leading, spacing: 8) {
                    LocalStatisticsComparisonPair {
                        cell("paired.words.microphone", height: wordHeight)
                    } trailing: {
                        cell("paired.duration.microphone", height: durationHeight)
                    }
                    LocalStatisticsComparisonPair {
                        cell("paired.words.file", height: wordHeight)
                    } trailing: {
                        cell("paired.duration.file", height: durationHeight)
                    }
                    LocalStatisticsComparisonPair {
                        Color.clear.frame(height: 0)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    } trailing: {
                        cell("paired.duration.caption", height: 14)
                    }
                }
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        cell("compact.words.microphone", height: wordHeight)
                        cell("compact.words.file", height: wordHeight)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        cell("compact.duration.microphone", height: durationHeight)
                        cell("compact.duration.file", height: durationHeight)
                        cell("compact.duration.caption", height: 14)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }

        private func cell(_ name: String, height: CGFloat) -> some View {
            Color.clear.frame(maxWidth: .infinity).frame(height: height)
                .background(StatisticsLayoutProbe(name: name))
        }
    }

    private struct StatisticsLayoutProbe: NSViewRepresentable {
        let name: String
        func makeNSView(context: Context) -> StatisticsLayoutProbeView { StatisticsLayoutProbeView(name: name) }
        func updateNSView(_ view: StatisticsLayoutProbeView, context: Context) {}
    }

    private final class StatisticsLayoutProbeView: NSView {
        let probeName: String
        init(name: String) { probeName = name; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("No archive decoding in the synthetic layout fixture") }
    }
}
