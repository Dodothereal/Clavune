"""Portable source contracts for the native Statistics page."""
import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
APP = ROOT / "Sources" / "ClavuneApp"


class StatisticsPageSourceContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.page = (APP / "LocalStatisticsPageView.swift").read_text()
        cls.model = (APP / "LocalStatisticsPageModel.swift").read_text()
        cls.presentation = (APP / "Presentation.swift").read_text()
        cls.language = (APP / "UILanguage.swift").read_text()

    def test_every_statistics_copy_key_has_english_translation_except_german_autonym(self):
        keys = set(re.findall(r'ui\.text\("([^"\\]*(?:\\.[^"\\]*)*)"\)', self.page))
        keys.update(re.findall(r'return "([^"\\]*(?:\\.[^"\\]*)*)"', self.page))
        keys.add("Statistiken")
        # The existing interface-language choice deliberately keeps this autonym.
        missing = sorted(key for key in keys if key != "Deutsch" and f'"{key}":' not in self.language)
        self.assertEqual(missing, [])
        self.assertIn('ui.text(LanguageMode.de.title)', self.page)
        self.assertIn('ui.text(LanguageMode.en.title)', self.page)
        self.assertIn('"Deutsch mit englischen Fachbegriffen": "German with English technical terms"',
                      self.language)

    def test_refresh_is_explicit_and_qa_does_not_invoke_loader(self):
        self.assertIn(".onAppear { _ = model.refresh(qaDisabled: qaDisabled) }", self.page)
        self.assertIn(".onDisappear { model.leave() }", self.page)
        self.assertIn("guard !qaDisabled else { state = .qaUnavailable; return nil }", self.model)
        self.assertLess(self.model.index("guard !qaDisabled"), self.model.index("let loader = self.loader"))
        for forbidden in ("Timer.", ".autoconnect()", ".onReceive(", "NSPasteboard.general"):
            self.assertNotIn(forbidden, self.page + self.model)

    def test_stable_qa_preview_uses_in_memory_source_and_cannot_export(self):
        source = (APP / "LocalStatisticsSyntheticPreview.swift").read_text()
        app = (APP / "ClavuneApp.swift").read_text()
        self.assertIn("statisticsPreviewInQA: coordinator.launchConfiguration.isQA", app)
        self.assertIn("let preview = statisticsPreviewInQA && coordinator.launchConfiguration.isQA",
                      self.presentation)
        self.assertIn("loader: { period in try await LocalStatisticsSyntheticPreview.load(period) }",
                      self.presentation)
        self.assertIn("guard !qaDisabled && !isSyntheticPreview else { return nil }", self.page)
        self.assertIn("if !isSyntheticPreview {", self.page)
        for forbidden in ("LocalMetricsJournal", "LocalStatisticsDiskLoader", "FileManager", "NSPasteboard"):
            self.assertNotIn(forbidden, source)

    def test_period_and_stale_result_guards_are_source_visible(self):
        for text in ("case last24Hours, last7Days, last30Days, retained", "generation &+= 1",
                     "self.generation == request", "!Task.isCancelled", "func leave()"):
            self.assertIn(text, self.model)
        self.assertIn("report.invalidTimestampEvents > 0", self.model)
        self.assertIn("report.invalidRecordEvents > 0", self.model)
        self.assertIn("result.report.period == period", self.model)
        self.assertIn("Date(timeIntervalSince1970: -Double.greatestFiniteMagnitude)", self.model)
        self.assertNotIn("case .retained: start = Date(timeIntervalSince1970: 0)", self.model)

    def test_compact_period_control_uses_the_shared_custom_choice(self):
        self.assertIn('ObservatorySettingChoice(title: ui.text("Zeitraum"), selection: periodBinding,',
                      self.page)
        self.assertIn('options: LocalStatisticsPeriod.allCases.map', self.page)
        self.assertIn('(value: $0, title: ui.text($0.titleKey))', self.page)
        self.assertNotIn('Picker(ui.text("Zeitraum"), selection: periodBinding)', self.page)
        self.assertIn('.accessibilityLabel(ui.text("Statistik aktualisieren"))', self.page)
        self.assertIn('DisclosureGroup(ui.text("Details"))', self.page)
        self.assertIn('.accessibilityLabel(title + " · " + ui.text("Alle Messwerte und Aktionen"))', self.page)
        self.assertIn('value ?? ui.text("nicht gemessen")', self.page)

    def test_source_plots_show_concrete_common_scales_and_neutral_elapsed_marks(self):
        # Source wiring only; the Swift numerical tests remain a native gate.
        self.assertIn('LocalStatisticsPlotScale.words([microphoneWords.sum, fileWords.sum])', self.page)
        self.assertIn('LocalStatisticsPlotScale.elapsedSeconds([microphoneDecode.mean, fileDecode.mean])',
                      self.page)
        self.assertIn('Text(plotText.scaleLabel(scale))', self.page)
        self.assertIn('Text(plotText.durationMeaning)', self.page)
        self.assertIn('if isDuration {', self.page)
        self.assertIn('Circle().fill(ObservatoryAppearance.ink)', self.page)
        self.assertIn('.transaction { $0.animation = nil }', self.page)
        self.assertNotIn('Maximum = 100 %', self.page)
        self.assertNotIn('Double(microphone.sum ?? 0) / Double(maximum)', self.page)
        self.assertNotIn('$0 / maximum', self.page)

    def test_summary_numbers_share_one_nonwrapping_line_with_their_labels(self):
        summary = self.page.split('    private func overviewValue(', 1)[1].split(
            '    private func comparisonHeading', 1)[0]
        self.assertIn('Text(title + "  ")', summary)
        self.assertIn('Text(value)', summary)
        self.assertIn('.lineLimit(1)', summary)
        self.assertIn('.fixedSize(horizontal: true, vertical: false)', summary)
        self.assertNotIn('VStack', summary)
        self.assertNotIn('size: 26', summary)
        self.assertIn('.accessibilityLabel(title)', summary)
        self.assertIn('.accessibilityValue(accessibleValue ?? value)', summary)

    def test_duration_axes_show_real_noninteractive_unit_endpoints(self):
        helper = (APP / 'LocalStatisticsPlotPresentation.swift').read_text()
        native = (ROOT / 'Tests/ClavuneCoreTests/LocalStatisticsPlotPresentationTests.swift').read_text()
        self.assertIn('let endpoints = plotText.axisEndpoints(scale)', self.page)
        self.assertIn('Text(endpoints.lower)', self.page)
        self.assertIn('Text(endpoints.upper)', self.page)
        self.assertIn('path.addLine(to: CGPoint(x: x, y: 7))', self.page)
        self.assertIn('.allowsHitTesting(false)', self.page)
        self.assertIn('number(scale.upperBound, roundingUp: true)', helper)
        self.assertIn('scale.unit.symbol(english: english)', helper)
        self.assertIn('testDurationAxisEndpointsUseTheExistingCommonBoundAndUnit', native)
        self.assertIn('testDurationAxisEndpointsLocalizeWithoutLosingSmallValuesOrUnits', native)

    def test_wide_plots_pair_sources_by_natural_row_height_only(self):
        paired = self.page.split('    private func pairedComparisons(', 1)[1].split(
            '    private func wordComparison(', 1)[0]
        self.assertEqual(paired.count('LocalStatisticsComparisonPair {'), 4)
        for source, word, duration in [('Mikrofon', 'microphoneWords', 'microphoneDecode'),
                                       ('Audiodatei', 'fileWords', 'fileDecode')]:
            self.assertIn(f'wordComparisonRow(ui.text("{source}"), {word}, scale: wordScale)', paired)
            self.assertIn(f'decodeComparisonRow(ui.text("{source}"), {duration}, scale: decodeScale)', paired)
        self.assertTrue(paired.index('fileDecode, scale: decodeScale)') < paired.index('            durationMeaning'))
        component = self.page.split('struct LocalStatisticsComparisonPair<', 1)[1].split(
            'private extension LocalStatisticsPeriod', 1)[0]
        self.assertIn('HStack(alignment: .top, spacing: 20)', component)
        self.assertEqual(component.count('.frame(minWidth: 300, maxWidth: .infinity, alignment: .leading)'), 2)
        for forbidden in ('height:', '.padding(', 'Spacer(', '.hidden()', '.opacity('):
            self.assertNotIn(forbidden, component)

    def test_elapsed_qualification_is_under_time_column_not_word_column(self):
        paired = self.page.split('    private func pairedComparisons(', 1)[1].split(
            '    private func wordComparison(', 1)[0]
        caption_pair = paired.rsplit('LocalStatisticsComparisonPair {', 1)[1]
        leading, trailing = caption_pair.split('} trailing: {', 1)
        self.assertIn('Color.clear.frame(height: 0)', leading)
        self.assertIn('.allowsHitTesting(false)', leading)
        self.assertIn('.accessibilityHidden(true)', leading)
        self.assertNotIn('Text(', leading)
        self.assertNotIn('durationMeaning', leading)
        self.assertEqual(trailing.count('durationMeaning'), 1)
        self.assertNotIn('Ältere Messpunkte können fehlen', paired)
        self.assertEqual(self.page.count('Text(plotText.durationMeaning)'), 1)
        self.assertEqual(self.page.count('Text(ui.text("Ältere Messpunkte können fehlen"))'), 1)
        native = (ROOT / 'Tests/ClavuneCoreTests/LocalStatisticsPlotPresentationTests.swift').read_text()
        self.assertIn('XCTAssertEqual(durationCaption.minX, durationFile.minX, accuracy: 0.5', native)
        self.assertIn('XCTAssertEqual(durationCaption.width, durationFile.width, accuracy: 0.5)', native)
        self.assertIn('top(durationCaption) - top(durationFile)', native)
        self.assertIn('cell("paired.duration.caption", height: 14)', native)
        self.assertIn('cell("compact.duration.caption", height: 14)', native)

    def test_compact_plot_rhythm_and_shared_exact_value_rows_are_preserved(self):
        self.assertIn('''VStack(alignment: .leading, spacing: 14) {
                    wordComparison(microphoneWords, fileWords, scale: wordScale)
                    decodeComparison(microphoneDecode, fileDecode, scale: decodeScale)
                }''', self.page)
        for invariant in ('value: plotText.count(words.sum, compact: true)',
                          'accessibleValue: plotText.count(words.sum).map',
                          'observed: words.observed, unknown: words.unknown, isDuration: false',
                          'value: plotText.duration(measurement.mean, on: scale)',
                          'observed: measurement.observed, unknown: measurement.unknown, isDuration: true'):
            self.assertIn(invariant, self.page)
        native = (ROOT / 'Tests/ClavuneCoreTests/LocalStatisticsPlotPresentationTests.swift').read_text()
        for invariant in ('testPairedSourceRowsAlignAtWideWidthsAndKeepCompactBoundary',
                          '[516, 619, 620, 736]', '[(24, 42), (62, 42), (24, 66)]',
                          'max(wordHeight, durationHeight) + 8',
                          'CLAVUNE_RUN_UI_HOST_FIXTURES', 'XCTAssertFalse(window.isVisible)'):
            self.assertIn(invariant, native)

    def test_plot_helper_preserves_missing_zero_units_and_native_numeric_tests(self):
        helper = (APP / 'LocalStatisticsPlotPresentation.swift').read_text()
        native = (ROOT / 'Tests/ClavuneCoreTests/LocalStatisticsPlotPresentationTests.swift').read_text()
        for invariant in ('filter { $0.isFinite && $0 >= 0 }',
                          'guard let maximum = valid.max() else { return nil }',
                          'guard maximum > 0 else { return 1 }',
                          'candidate.isFinite && candidate >= maximum',
                          'upperBound.isFinite, upperBound > 0',
                          'case words, milliseconds, seconds, minutes, hours',
                          'not a performance score', 'Preview data · no journal read'):
            self.assertIn(invariant, helper)
        for case in ('testMeasuredZeroHasAnExplicitFiniteScaleAndMarkerPosition',
                     'testMissingAndInvalidValuesNeverBecomeZeroObservations',
                     'testNiceBoundaryNeverRoundsBelowTheMaximum',
                     'testExtremesRemainFiniteAndDoNotClampToAnInventedCap',
                     'testExistingSyntheticAggregateIsUnmodifiedByPresentation'):
            self.assertIn(case, native)
        self.assertIn('Text(plotText.previewProvenance)', self.page)

    def test_statistics_navigation_keeps_review_shell_and_capture_controls(self):
        self.assertIn("statisticsVisible: statisticsNavigationBinding", self.presentation)
        self.assertIn("statisticsTitle: ui.text(\"Statistiken\")", self.presentation)
        self.assertIn("TranscriptEditor(text: $coordinator.editedText, isPresented: !settingsVisible,",
                      self.presentation)
        self.assertEqual(self.presentation.count("clipboardWriteSink: coordinator.qaTranscriptClipboardSink)"), 2)
        self.assertIn("if coordinator.hotkeyRecording { coordinator.cancelHotkeyRecording() }",
                      self.presentation)
        self.assertIn(".id(coordinator.session.id)", self.presentation)
        self.assertIn("Button(ui.text(\"Stoppen\"), action: coordinator.stop)", self.presentation)
        self.assertIn("Button(ui.text(\"Abbrechen\"), action: coordinator.cancel)", self.presentation)
        self.assertIn("if statisticsVisible {", self.presentation)


if __name__ == "__main__":
    unittest.main()
