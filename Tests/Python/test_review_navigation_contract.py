"""Source wiring only; real native Undo/navigation is a separate required gate."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ReviewNavigationSourceContracts(unittest.TestCase):
    def test_navigation_hides_without_conditionally_replacing_review_host(self):
        source = (ROOT / 'Sources/ClavuneApp/Presentation.swift').read_text()
        self.assertNotIn('if !settingsVisible {', source)
        for invariant in ['ZStack(alignment: .topLeading)',
                          '.frame(height: settingsVisible ? 0 : nil, alignment: .top)',
                          '.allowsHitTesting(!settingsVisible)', '.accessibilityHidden(settingsVisible)',
                          '.id(coordinator.session.id)',
                          'editor.isSelectable = isPresented; view.isHidden = !isPresented',
                          'window.firstResponder === editor', 'window.makeFirstResponder(nil)',
                          'context.coordinator.clearUndoHistory()', 'coordinator.detach()']:
            self.assertIn(invariant, source)
        native = (ROOT / 'Tests/ClavuneCoreTests/ReviewNavigationReadinessTests.swift').read_text()
        for assertion in ['control.sendAction(action, to: control.target)',
                          'Settings is not a new review', 'undo.undo()', 'undo.redo()',
                          'XCTAssertFalse(undo.canUndo)', 'XCTAssertFalse(undo.canRedo)',
                          'XCTAssertFalse(window.firstResponder === original)',
                          '.transaction { $0.disablesAnimations = true; $0.animation = nil }']:
            self.assertIn(assertion, native)
