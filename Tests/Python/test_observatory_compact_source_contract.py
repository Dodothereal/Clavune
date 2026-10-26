"""Portable wiring guards only; macOS compilation and pixel/interaction QA remain required."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "Sources/ClavuneApp"


class ObservatoryCompactSourceContracts(unittest.TestCase):
    def test_phase_actions_are_pinned_but_editor_is_not_duplicated(self):
        source = (APP / "Presentation.swift").read_text()
        body = source.split("    var body: some View {", 1)[1]
        toolbar = body.split("            phaseToolbar\n", 1)[1].split("            ScrollView {", 1)[0]
        self.assertIn(".accessibilityHidden(phaseToolbarHidden)", toolbar)
        self.assertIn(".allowsHitTesting(!phaseToolbarHidden)", toolbar)
        self.assertIn("settingsVisible && !coordinator.session.phase.isBusy", source)
        self.assertIn("(!settingsVisible && coordinator.busy) || coordinator.session.phase.isBusy", body)
        self.assertEqual(source.count("TranscriptEditor(text: $coordinator.editedText"), 1)
        self.assertEqual(source.count(".id(coordinator.session.id)"), 1)
        self.assertEqual(source.count("clipboardWriteSink: coordinator.qaTranscriptClipboardSink"), 2)
        review = body.split("ZStack(alignment: .topLeading)", 1)[1]
        self.assertNotIn("reviewCommandRow", review)
        self.assertNotIn("idleCommandRow", review)

    def test_display_polish_keeps_real_action_and_hotkey_admission(self):
        source = (APP / "Presentation.swift").read_text()
        for guard in [".disabled(!coordinator.canStart)", ".disabled(!coordinator.canImportAudio)",
                      ".disabled(!coordinator.canOpenTranscript)", ".disabled(!coordinator.canSaveTranscript)",
                      ".disabled(coordinator.transcriptFilePending)",
                      "if hadPending { coordinator.interruptForPrivacy() }",
                      "if !isVisible && ownsHotkeyRecording"]:
            self.assertIn(guard, source)
        self.assertIn('Label(ui.text("Vorschau"), systemImage: "square.dashed")', source)
        self.assertIn("Aufnahme in Vorschau deaktiviert", source)
        self.assertIn("Modellaktionen deaktiviert; keine Gewichte geladen", source)
        self.assertIn("coordinator.microphone.state == .closed", source)
        self.assertNotIn("replacingOccurrences", source)

    def test_settings_fields_keep_full_value_and_focus_affordance(self):
        controls = (APP / "ObservatoryControls.swift").read_text()
        settings = controls.split("struct ObservatorySettingChoice", 1)[1].split("/// Drop-in visual replacement", 1)[0]
        self.assertNotIn(".lineLimit(2)", settings)
        self.assertNotIn(".overlay(alignment: .leading)", settings)
        self.assertIn(".help(selectedTitle)", settings)
        self.assertIn(".accessibilityValue(selectedTitle)", settings)
        self.assertIn("configuration.isOn ? onLabel : offLabel", settings)
        self.assertIn("isEnabled && isFocused", controls)
        self.assertIn("motion.duration = 0.14", controls)
        self.assertIn("if reducedMotion { underlineLayer.removeAllAnimations() }", controls)

    def test_static_render_uses_writable_force_only_motion_key_and_observed_policy(self):
        controls = (APP / "ObservatoryControls.swift").read_text()
        render = (ROOT / "Tests/ClavuneCoreTests/QAContentRenderTests.swift").read_text()
        motion_tests = (ROOT / "Tests/ClavuneCoreTests/ObservatoryNavigationMotionTests.swift").read_text()
        self.assertIn("var observatoryForceReducedMotion: Bool", controls)
        self.assertIn("defaultValue = false", controls)
        self.assertEqual(controls.count("control.reducedMotion = reduceMotion || forceReducedMotion"), 2)
        self.assertIn(r".environment(\.observatoryForceReducedMotion, true)", render)
        self.assertNotIn(r".environment(\.accessibilityReduceMotion", render)
        self.assertIn("try verifyReducedMotion(in: host)", render)
        self.assertIn("reduceMotion: observedReducedMotion", render)
        self.assertIn("clavune.selection", render)
        self.assertIn("observatoryForceReducedMotion", motion_tests)

    def test_ime_refresh_preserves_only_same_binding_composition(self):
        source = (APP / "Presentation.swift").read_text()
        native_tests = (ROOT / "Tests/ClavuneCoreTests/ObservatoryCompactPresentationTests.swift").read_text()
        self.assertIn("preserveMarkedText(in: editor, incomingText: incomingText)", source)
        self.assertIn("textView.isEditable, textView.hasMarkedText()", source)
        self.assertIn("TranscriptTextIdentity.matches($0, incomingText)", source)
        self.assertIn("sameBinding || TranscriptTextIdentity.matches(textView.string, incomingText)", source)
        self.assertIn("context.coordinator.clearUndoHistory()", source)
        self.assertIn("editor.string = incomingText", source)
        self.assertIn("testAnotherHostEditWhileMarkedReplacesDraftAndClearsOnlyStaleUndo", native_tests)
        self.assertIn("XCTAssertTrue(editor.hasMarkedText()", native_tests)

    def test_render_binding_uses_physical_components_without_relaxing_inventory(self):
        source = (ROOT / "Tests/ClavuneCoreTests/QAContentEvidenceSupport.swift").read_text()
        self.assertIn("Darwin.realpath(path, nil)", source)
        self.assertIn("Array(file.prefix(root.count)) == root", source)
        self.assertNotIn("dropFirst(root.path.count + 1)", source)
        self.assertIn("guard actual == Set(paths)", source)
        self.assertIn("values.isSymbolicLink != true", source)
        self.assertIn("lstat(checkedPath, &info)", source)
        self.assertIn("Darwin.open(temporaryRootPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW", source)
        self.assertIn("O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW", source)

    def test_native_completion_boundaries_do_not_retain_stale_undo_or_close_state(self):
        source = (APP / "Presentation.swift").read_text()
        replacement = source.split("if !TranscriptTextIdentity.matches(editor.string, incomingText)", 1)[1]
        replacement = replacement.split("context.coordinator.recordSynchronizedText(incomingText)", 1)[0]
        self.assertEqual(replacement.count("context.coordinator.clearUndoHistory()"), 2)
        self.assertIn("editor.string = incomingText", replacement)
        self.assertLess(replacement.index("editor.string = incomingText"), replacement.rindex("clearUndoHistory()"))
        tests = (ROOT / "Tests/ClavuneCoreTests/InstalledModelSelectionTests.swift").read_text()
        cancellation = tests.split("func testFreshCheckAndSelectionAfterCancellationKeepTheirOwnResult", 1)[1]
        for name in ["closedCheck", "closedSelection"]:
            observation = cancellation.index("fixture.observeCloseFinished(" + name + ")")
            self.assertIn("fixture.coordinator.cancel()", cancellation[:observation])
            self.assertGreater(cancellation[:observation].rindex("fixture.coordinator.cancel()"),
                               cancellation[:observation].rindex("let " + name))
        self.assertEqual(cancellation.count("guard !fixture.coordinator.operationPending, !fixture.coordinator.closePending"), 2)

    def test_native_overflow_cue_uses_real_scroll_geometry_not_a_text_mask(self):
        source = (APP / "Presentation.swift").read_text()
        editor = source.split("struct TranscriptEditor: NSViewRepresentable", 1)[1]
        make = editor.split("    func updateNSView", 1)[0]
        self.assertIn("scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true", make)
        self.assertIn("scroll.scrollerStyle = .legacy", make)
        self.assertIn("scroll.scrollerKnobStyle = .light", make)
        self.assertIn("editor.font = .systemFont(ofSize: 15)", make)
        self.assertNotIn(".mask(", editor)
        self.assertNotIn("LinearGradient", editor)
        tests = (ROOT / "Tests/ClavuneCoreTests/ObservatoryCompactPresentationTests.swift").read_text()
        for check in ["testReviewNativeScrollerRepresentsOverflowAndReachesFinalLineAtBothWidths",
                      "XCTAssertFalse(scroller.isHidden", "XCTAssertTrue(scroller.isHidden",
                      "XCTAssertLessThan(scroller.knobProportion, 1)", "editor.scrollRangeToVisible(lastCharacter)",
                      "XCTAssertEqual(editor.selectedRange(), selection)"]:
            self.assertIn(check, tests)

    def test_settings_column_is_bounded_without_changing_statistics_field_width(self):
        source = (APP / "Presentation.swift").read_text()
        tokens = (APP / "ObservatoryAppearance.swift").read_text()
        controls = (APP / "ObservatoryControls.swift").read_text()
        self.assertIn("static let fieldWidth: CGFloat = 188", tokens)
        self.assertIn("static let settingsFieldWidth: CGFloat = 228", tokens)
        self.assertIn("static let settingsColumnWidth: CGFloat = 480", tokens)
        self.assertIn(".frame(maxWidth: ObservatoryAppearance.settingsColumnWidth, alignment: .leading)", source)
        self.assertEqual(controls.count("var fieldWidth: CGFloat = ObservatoryAppearance.fieldWidth"), 2)
        shortcut = source.split('// Keep the shortcut and the actions that change it', 1)[1]
        shortcut = shortcut.split('FocusedHotkeyRecorder(', 1)[0]
        self.assertIn('coordinator.developmentShortcut.title', shortcut)
        self.assertIn('ownsHotkeyRecording = coordinator.beginHotkeyRecording()', shortcut)
        self.assertIn('coordinator.cancelHotkeyRecording()', shortcut)
        self.assertIn('.disabled(coordinator.busy || coordinator.launchConfiguration.isQA)', shortcut)
        self.assertIn('role == .primary ? .medium : .regular', controls)

    def test_settings_column_is_centered_and_input_rule_spans_its_action(self):
        source = (APP / "Presentation.swift").read_text()
        settings = source.split('if settingsVisible && !statisticsVisible {', 1)[1]
        settings = settings.split('if statisticsVisible {', 1)[0]
        column = settings.split('.frame(maxWidth: ObservatoryAppearance.settingsColumnWidth, alignment: .leading)', 1)[1]
        self.assertIn('.frame(maxWidth: .infinity, alignment: .center)', column)
        heading = settings.split('settingsHeading("Eingabe", showsDivider: false)', 1)[1]
        heading = heading.split('ObservatorySettingChoice(title: ui.text("Erkennungssprache")', 1)[0]
        self.assertIn('Button(ui.text("Geräte aktualisieren"), action: coordinator.refreshDevices)', heading)
        self.assertIn('.disabled(coordinator.busy)', heading)
        self.assertIn('.overlay(alignment: .bottom) { ObservatoryAppearance.rule.frame(height: 1) }', heading)

    def test_settings_seam_uses_real_viewport_space_not_masks_or_render_exceptions(self):
        source = (APP / "Presentation.swift").read_text()
        self.assertIn('.padding(.vertical, settingsVisible ? ObservatoryAppearance.scrollViewportGutter : 0)', source)
        self.assertNotIn('.mask(', source)
        self.assertNotIn('LinearGradient', source)
        tokens = (APP / "ObservatoryAppearance.swift").read_text()
        self.assertIn('static let scrollViewportGutter: CGFloat = 8', tokens)
        self.assertIn('static let settingsViewportGutter: CGFloat = scrollViewportGutter', tokens)
        tests = (ROOT / "Tests/ClavuneCoreTests/ObservatoryCompactPresentationTests.swift").read_text()
        fixture = tests.split('func testSettingsViewportGutterAndRealEndReachabilityAtBothWidthsAndLanguages', 1)[1]
        fixture = fixture.split('func testReviewNativeScroller', 1)[0]
        for check in ['for language in UILanguage.allCases', 'for width: CGFloat in [560, 780]',
                      'XCTAssertEqual(topGap, ObservatoryAppearance.settingsViewportGutter',
                      'XCTAssertEqual(bottomGap, ObservatoryAppearance.settingsViewportGutter',
                      'XCTAssertEqual(clip.bounds.minY, maxY',
                      'XCTAssertEqual(clip.bounds.maxY, document.frame.height',
                      'fieldFrame.maxX, viewportOnScreen.midX + ObservatoryAppearance.settingsColumnWidth / 2',
                      'contains(lastFrame)', 'XCTAssertTrue(try lastControl.isAccessibilityEnabled())']:
            self.assertIn(check, fixture)

    def test_secondary_pages_share_real_gutter_without_a_second_top_rule(self):
        source = (APP / "Presentation.swift").read_text()
        boundary = source.split('.scrollIndicators(settingsVisible && !statisticsVisible ? .visible : .automatic)', 1)[1]
        boundary = boundary.split('.padding(.horizontal, isAuxiliaryPanel', 1)[0]
        self.assertNotIn('.overlay(alignment: .top)', boundary)
        self.assertIn('.padding(.vertical, settingsVisible ? ObservatoryAppearance.scrollViewportGutter : 0)', boundary)
        self.assertIn('.background(alignment: .bottom) { ObservatoryAppearance.rule.frame(height: 1) }', source)
        tests = (ROOT / "Tests/ClavuneCoreTests/ObservatoryCompactPresentationTests.swift").read_text()
        fixture = tests.split('func testStatisticsViewportGutterPreservesSyntheticTrueEndAtBothWidthsAndLanguages', 1)[1]
        fixture = fixture.split('func testReviewNativeScroller', 1)[0]
        for check in ['for language in UILanguage.allCases', 'for width: CGFloat in [560, 780]',
                      'LocalStatisticsSyntheticPreview.load(period)', 'statisticsPreviewModel: model',
                      'XCTAssertEqual(result.diagnostics.readFiles, 0)',
                      'XCTAssertEqual(topGap, ObservatoryAppearance.scrollViewportGutter',
                      'for offset in [CGFloat.zero, maxY / 2, maxY]',
                      'XCTAssertEqual(clip.bounds.maxY, document.frame.height']:
            self.assertIn(check, fixture)
        self.assertNotIn('LocalStatisticsDiskLoader', fixture)
        self.assertNotIn('valueElement(', fixture)

    def test_hidden_settings_ax_adapter_reads_only_public_observed_attributes(self):
        tests = (ROOT / "Tests/ClavuneCoreTests/ObservatoryCompactPresentationTests.swift").read_text()
        adapter = tests.split('private struct OwnedAXNode', 1)[1].split('@MainActor func testSettingsViewportGutter', 1)[0]
        for check in ['object as? NSAccessibilityProtocol', 'object.accessibilityAttributeNames()',
                      'advertised.contains(name)', 'object.accessibilityAttributeValue(name)',
                      'String(cString: position.objCType)', 'String(cString: size.objCType)',
                      'frame.size.width > 0, frame.size.height > 0',
                      'value.doubleValue == 0 || value.doubleValue == 1',
                      'OwnedAXReadFailure.cycle', 'OwnedAXReadFailure.depthLimit', 'OwnedAXReadFailure.nodeLimit']:
            self.assertIn(check, adapter)
        for forbidden in ['NSSelectorFromString', 'unsafeBitCast', 'accessibilitySetValue',
                          'accessibilitySetOverrideValue', 'value(forKey:', 'AXUIElementCreate',
                          'SwiftUI.AccessibilityNode', 'object_getClass']:
            self.assertNotIn(forbidden, tests)
        self.assertEqual(tests.count(r'.environment(\.accessibilityEnabled, true)'), 1)
        for test in ['testOwnedAXAdapterReadsModernAndAdvertisedLegacyNodesWithoutCoordinateFlips',
                     'testOwnedAXAdapterRejectsMissingOrMalformedRequiredAttributes',
                     'testOwnedAXAdapterRejectsNonfiniteAndNonpositiveFramesOnBothPaths',
                     'testOwnedAXAdapterBoundsCyclesDepthAndNodeCountWithoutInventingMatches']:
            self.assertIn(test, tests)

    def test_editor_sizing_does_not_resize_normal_or_auxiliary_windows(self):
        layout = (APP / "QAAdaptiveWindowSize.swift").read_text()
        self.assertIn("guard isQA && !isAuxiliaryPanel else { return nil }", layout)
        self.assertIn("static let compactHeight: CGFloat = 200", layout)
        self.assertIn("if bytes <= 180 { return (360,", layout)
        self.assertIn("if bytes <= 1_200 { return (440,", layout)
        self.assertIn("return (580,", layout)
        self.assertIn("window.setFrame(frame, display: true, animate: false)", layout)


    def test_review_metadata_never_claims_saved_from_binding_state_and_frame_is_noninteractive(self):
        source = (APP / "Presentation.swift").read_text()
        metadata = source.split("private var reviewStatusStrip:", 1)[1].split("private var qaWindowHeight:", 1)[0]
        self.assertIn("if coordinator.hasUnsavedReview", metadata)
        self.assertIn('Text(ui.text("Ungespeichert"))', metadata)
        self.assertNotIn("Gespeichert", metadata)
        editor = source.split('TranscriptEditor(text: $coordinator.editedText', 1)[1]
        editor = editor.split('.accessibilityLabel(ui.text("Bearbeitbare Transkriptvorschau"))', 1)[0]
        self.assertEqual(editor.count(".allowsHitTesting(false)"), 2)
        self.assertEqual(editor.count(".accessibilityHidden(true)"), 2)


if __name__ == "__main__":
    unittest.main()
