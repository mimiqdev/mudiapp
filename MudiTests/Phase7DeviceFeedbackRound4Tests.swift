import HerdrKit
import SwiftUI
import UIKit
import XCTest
@preconcurrency import SwiftTerm
@testable import Mudi

/// Physical-device feedback round 4: popup visibility is driven by a single
/// `activePopup` state - at most one popup is visible, opening any popup
/// replaces the previous one, and opening the D-pad clears a latched Ctrl
/// so subsequent arrows send unmodified sequences.
@MainActor
final class Phase7DeviceFeedbackRound4Tests: XCTestCase {
    @MainActor
    private struct ExclusionFixture {
        let window: UIWindow
        let bar: MudiTerminalShortcutBar
        let terminalView: ShellTerminalView
        let controlButton: UIButton
        let dpadButton: UIButton
        let popup: UIView
        let overlay: UIView
        let recorder: Phase7TerminalInputRecorder

        func teardown() {
            terminalView.stop()
            window.isHidden = true
        }
    }

    private func makeExclusionFixture() throws -> ExclusionFixture {
        let terminalView = ShellTerminalView(frame: .zero)
        let harness = Phase7TerminalViewHarness(terminalView: terminalView)
        let recorder = Phase7TerminalInputRecorder()
        terminalView.terminalDelegate = recorder
        let bar = try XCTUnwrap(terminalView.shortcutBar)
        harness.window.layoutIfNeeded()
        let controlButton = try XCTUnwrap(
            phase7View(with: "terminal-shortcut-control", in: bar) as? UIButton
        )
        let dpadButton = try XCTUnwrap(
            phase7View(with: "terminal-shortcut-dpad", in: bar) as? UIButton
        )
        let popup = try XCTUnwrap(
            phase7View(with: "terminal-control-combo-popup", in: bar)
        )
        let overlay = try XCTUnwrap(
            phase7View(with: "terminal-dpad-overlay", in: bar)
        )
        return ExclusionFixture(
            window: harness.window,
            bar: bar,
            terminalView: terminalView,
            controlButton: controlButton,
            dpadButton: dpadButton,
            popup: popup,
            overlay: overlay,
            recorder: recorder
        )
    }

    func testOpeningSecondPopupReplacesFirstAtStateLevel() throws {
        let fixture = try makeExclusionFixture()
        defer { fixture.teardown() }

        // Open the Ctrl popup: state moves to .ctrlCombo.
        fixture.controlButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(fixture.bar.activePopup, .ctrlCombo)
        XCTAssertTrue(fixture.terminalView.controlModifier)
        XCTAssertFalse(fixture.popup.isHidden)

        // Opening the D-pad replaces the popup at the state level: exactly
        // one case is active, the popup closes, the latch clears, and the
        // card shows.
        fixture.dpadButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(fixture.bar.activePopup, .dPad)
        XCTAssertTrue(fixture.terminalView.controlModifier == false)
        XCTAssertTrue(
            fixture.popup.isHidden,
            "The replaced popup must close"
        )
        XCTAssertFalse(
            fixture.overlay.isHidden,
            "The newly opened popup must be visible"
        )
        XCTAssertFalse(fixture.controlButton.isSelected)
        XCTAssertTrue(fixture.dpadButton.isSelected)

        // Opening the Ctrl popup replaces the D-pad at the state level.
        fixture.controlButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(fixture.bar.activePopup, .ctrlCombo)
        XCTAssertTrue(fixture.terminalView.controlModifier)
        XCTAssertTrue(fixture.overlay.isHidden)
        XCTAssertFalse(fixture.popup.isHidden)
    }

    func testSwitchingToDPadSendsUnmodifiedArrowsAfterwards() throws {
        let fixture = try makeExclusionFixture()
        defer { fixture.teardown() }

        // Latch Ctrl, then switch to the D-pad: the latch clears, so the
        // next arrow sends a plain sequence instead of a modified one.
        fixture.controlButton.sendActions(for: .touchUpInside)
        fixture.dpadButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(fixture.bar.activePopup, .dPad)
        XCTAssertFalse(fixture.terminalView.controlModifier)

        let upArrow = try XCTUnwrap(
            phase7View(with: "terminal-dpad-up", in: fixture.bar) as? UIButton
        )
        upArrow.sendActions(for: .touchUpInside)
        XCTAssertEqual(
            fixture.recorder.sentBytes.last,
            EscapeSequences.moveUpNormal,
            "Arrows after the latch cleared must be unmodified"
        )
    }

    func testTogglingPopupsReturnsStateToNone() throws {
        let fixture = try makeExclusionFixture()
        defer { fixture.teardown() }

        // Toggle the D-pad open, then closed: state clears.
        fixture.dpadButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(fixture.bar.activePopup, .dPad)
        fixture.dpadButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(fixture.bar.activePopup, .none)
        XCTAssertTrue(fixture.overlay.isHidden)

        // Toggle the Ctrl popup open, then closed: state clears and the
        // latch is released.
        fixture.controlButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(fixture.bar.activePopup, .ctrlCombo)
        fixture.controlButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(fixture.bar.activePopup, .none)
        XCTAssertFalse(fixture.terminalView.controlModifier)
        XCTAssertTrue(fixture.popup.isHidden)
    }
}
