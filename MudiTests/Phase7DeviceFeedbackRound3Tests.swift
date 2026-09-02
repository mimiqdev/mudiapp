import HerdrKit
import SwiftUI
import UIKit
import XCTest
@preconcurrency import SwiftTerm
@testable import Mudi

/// Physical-device feedback round 3: keyboard toggle glyph state, stable
/// inter-icon spacing across IME composition, shared glass treatment for
/// the popups, the new Ctrl+J combo, and the compact D-pad footprint.
@MainActor
final class Phase7DeviceFeedbackRound3Tests: XCTestCase {
    // MARK: 1 - keyboard toggle glyph reflects state

    func testKeyboardToggleGlyphReflectsKeyboardState() throws {
        let terminalView = ShellTerminalView(frame: .zero)
        let harness = Phase7TerminalViewHarness(terminalView: terminalView)
        defer {
            harness.close()
            terminalView.stop()
        }
        let bar = try XCTUnwrap(terminalView.shortcutBar)
        harness.window.layoutIfNeeded()
        let keyboardButton = try XCTUnwrap(
            phase7View(with: "terminal-shortcut-dismiss-keyboard", in: bar)
                as? UIButton
        )

        func glyph(_ name: String) -> UIImage? {
            UIImage(systemName: name)?
                .applyingSymbolConfiguration(
                    MudiTerminalShortcutBar.barSymbolConfiguration
                )
        }

        // Keyboard starts hidden: the button must offer "show keyboard".
        XCTAssertEqual(keyboardButton.image(for: .normal), glyph("keyboard"))
        XCTAssertEqual(keyboardButton.accessibilityLabel, "Show keyboard")

        // The keyboard glyph tracks the TERMINAL's own keyboard, so the
        // terminal must hold focus before the show notification counts.
        _ = terminalView.becomeFirstResponder()
        guard terminalView.isFirstResponder else {
            throw XCTSkip("Test host did not grant first-responder status")
        }

        NotificationCenter.default.post(
            name: UIApplication.keyboardDidShowNotification,
            object: nil
        )
        XCTAssertEqual(
            keyboardButton.image(for: .normal),
            glyph("keyboard.chevron.compact.down"),
            "While the keyboard is up the button must offer dismissal"
        )
        XCTAssertEqual(keyboardButton.accessibilityLabel, "Hide keyboard")

        NotificationCenter.default.post(
            name: UIApplication.keyboardDidHideNotification,
            object: nil
        )
        XCTAssertEqual(keyboardButton.image(for: .normal), glyph("keyboard"))
        XCTAssertEqual(keyboardButton.accessibilityLabel, "Show keyboard")
    }

    func testForeignKeyboardDoesNotCorruptToggleGlyph() throws {
        let terminalView = ShellTerminalView(frame: .zero)
        let harness = Phase7TerminalViewHarness(terminalView: terminalView)
        defer {
            harness.close()
            terminalView.stop()
        }
        let bar = try XCTUnwrap(terminalView.shortcutBar)
        harness.window.layoutIfNeeded()
        let keyboardButton = try XCTUnwrap(
            phase7View(with: "terminal-shortcut-dismiss-keyboard", in: bar)
                as? UIButton
        )

        func glyph(_ name: String) -> UIImage? {
            UIImage(systemName: name)?
                .applyingSymbolConfiguration(
                    MudiTerminalShortcutBar.barSymbolConfiguration
                )
        }

        // Terminal keyboard down: a keyboard shown elsewhere in the app
        // (pane-picker text field, etc.) must not flip the toggle glyph.
        NotificationCenter.default.post(
            name: UIApplication.keyboardDidShowNotification,
            object: nil
        )
        XCTAssertEqual(keyboardButton.image(for: .normal), glyph("keyboard"))
        XCTAssertEqual(keyboardButton.accessibilityLabel, "Show keyboard")

        // A keyboard hide keeps the glyph in the show-keyboard state.
        NotificationCenter.default.post(
            name: UIApplication.keyboardDidHideNotification,
            object: nil
        )
        XCTAssertEqual(keyboardButton.image(for: .normal), glyph("keyboard"))
        XCTAssertEqual(keyboardButton.accessibilityLabel, "Show keyboard")
    }

    // MARK: 2 - inter-icon spacing invariant across composition

    func testIconSpacingInvariantAcrossComposition() throws {
        let terminalView = ShellTerminalView(frame: .zero)
        let harness = Phase7TerminalViewHarness(terminalView: terminalView)
        defer {
            harness.close()
            terminalView.stop()
        }
        let bar = try XCTUnwrap(terminalView.shortcutBar)
        harness.window.layoutIfNeeded()

        func interIconGaps() -> [CGFloat] {
            let visible = phase7ShortcutButtons(in: bar)
                .filter { !$0.isHidden }
            var gaps: [CGFloat] = []
            for (previous, current) in zip(visible, visible.dropFirst()) {
                gaps.append(
                    current.frame.minX - (previous.frame.minX + previous.frame.width)
                )
            }
            return gaps
        }

        let initialGaps = interIconGaps()
        XCTAssertGreaterThanOrEqual(initialGaps.count, 5)

        bar.updateComposition(markedText: "nijiahao hen chang de pinyin biaoji")
        harness.window.layoutIfNeeded()
        bar.updateComposition(markedText: nil)
        harness.window.layoutIfNeeded()

        let restoredGaps = interIconGaps()
        XCTAssertEqual(
            initialGaps.count,
            restoredGaps.count,
            "The same buttons must be visible after composition"
        )
        for (initial, restored) in zip(initialGaps, restoredGaps) {
            XCTAssertEqual(
                initial,
                restored,
                accuracy: 0.5,
                "Composition must not permanently alter inter-icon spacing"
            )
        }
    }

    // MARK: 3a - shared glass treatment for popups

    func testOverlaysUseMaterialBackdrop() throws {
        let terminalView = ShellTerminalView(frame: .zero)
        let harness = Phase7TerminalViewHarness(terminalView: terminalView)
        defer {
            harness.close()
            terminalView.stop()
        }
        let bar = try XCTUnwrap(terminalView.shortcutBar)
        harness.window.layoutIfNeeded()

        let controlButton = try XCTUnwrap(
            phase7View(with: "terminal-shortcut-control", in: bar) as? UIButton
        )
        controlButton.sendActions(for: .touchUpInside)
        let dpadButton = try XCTUnwrap(
            phase7View(with: "terminal-shortcut-dpad", in: bar) as? UIButton
        )
        dpadButton.sendActions(for: .touchUpInside)
        harness.window.layoutIfNeeded()

        for identifier in [
            "terminal-control-combo-popup",
            "terminal-dpad-overlay",
        ] {
            let overlay = try XCTUnwrap(
                phase7View(with: identifier, in: bar),
                "\(identifier) must be present"
            )
            let materials = phase7Descendants(of: overlay)
                .compactMap { $0 as? UIVisualEffectView }
            XCTAssertEqual(
                materials.count,
                1,
                "\(identifier) must carry a glass/material backdrop"
            )
            XCTAssertNotNil(materials.first?.effect)
        }
    }

    // MARK: 3b - Ctrl+J combo

    func testComboPopupIncludesCtrlJ() throws {
        let terminalView = ShellTerminalView(frame: .zero)
        let harness = Phase7TerminalViewHarness(terminalView: terminalView)
        let recorder = Phase7TerminalInputRecorder()
        terminalView.terminalDelegate = recorder
        defer {
            harness.close()
            terminalView.stop()
        }
        let bar = try XCTUnwrap(terminalView.shortcutBar)
        harness.window.layoutIfNeeded()
        let controlButton = try XCTUnwrap(
            phase7View(with: "terminal-shortcut-control", in: bar) as? UIButton
        )
        controlButton.sendActions(for: .touchUpInside)
        let popup = try XCTUnwrap(
            phase7View(with: "terminal-control-combo-popup", in: bar)
        )

        let comboButtons = phase7Buttons(in: popup)
        XCTAssertEqual(
            comboButtons.map { $0.title(for: .normal) },
            ["C", "D", "L", "A", "E", "U", "K", "W", "J"],
            "The combo set is C D L A E U K W J"
        )

        let jCombo = try XCTUnwrap(comboButtons.last)
        jCombo.sendActions(for: .touchUpInside)
        XCTAssertEqual(
            recorder.sentBytes.last,
            [0x0A],
            "Ctrl+J must send 0x0A"
        )
    }

    // MARK: 4 - compact D-pad footprint

    func testDPadOverlayCompactFootprint() throws {
        let terminalView = ShellTerminalView(frame: .zero)
        let harness = Phase7TerminalViewHarness(terminalView: terminalView)
        defer {
            harness.close()
            terminalView.stop()
        }
        let bar = try XCTUnwrap(terminalView.shortcutBar)
        harness.window.layoutIfNeeded()
        let dpadButton = try XCTUnwrap(
            phase7View(with: "terminal-shortcut-dpad", in: bar) as? UIButton
        )
        dpadButton.sendActions(for: .touchUpInside)
        harness.window.layoutIfNeeded()
        let overlay = try XCTUnwrap(
            phase7View(with: "terminal-dpad-overlay", in: bar)
        )

        XCTAssertLessThanOrEqual(
            overlay.frame.width,
            160,
            "The D-pad card must keep a compact footprint"
        )
        XCTAssertLessThanOrEqual(
            overlay.frame.height,
            120,
            "The D-pad card must keep a compact footprint"
        )
    }
}
