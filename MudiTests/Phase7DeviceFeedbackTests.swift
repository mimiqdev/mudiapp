import HerdrKit
import SwiftUI
import UIKit
import XCTest
@preconcurrency import SwiftTerm
@testable import Mudi

/// Physical-device feedback round: keyboard toggle, IME composition row
/// layout, glass backdrop, and the floating D-pad card behavior.
@MainActor
final class Phase7DeviceFeedbackTests: XCTestCase {
    // MARK: device feedback - keyboard toggle, composition layout,
    // glass backdrop, floating D-pad

    // MARK: r4 - focus gate + drag offset re-clamp

    func testKeyboardToggleRespectsFocusGate() throws {
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

        // While the pane-picker focus gate is engaged, the toggle must not
        // summon the keyboard.
        terminalView.updateInputFocus(isAllowed: false)
        let becomeBefore = terminalView.becomeFirstResponderRequestCount
        keyboardButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(
            terminalView.becomeFirstResponderRequestCount,
            becomeBefore
        )

        // With focus allowed again, the toggle requests first responder.
        terminalView.updateInputFocus(isAllowed: true)
        keyboardButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(
            terminalView.becomeFirstResponderRequestCount,
            becomeBefore + 1
        )
    }

    func testDPadOverlayPositionReclampsAfterWidthShrink() throws {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 240))
        let terminalView = ShellTerminalView(frame: .zero)
        defer { terminalView.stop() }
        let bar = try XCTUnwrap(terminalView.shortcutBar)
        container.addSubview(bar)
        bar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 44)
        ])
        container.layoutIfNeeded()
        let dpadButton = try XCTUnwrap(
            phase7View(with: "terminal-shortcut-dpad", in: bar) as? UIButton
        )
        dpadButton.sendActions(for: .touchUpInside)
        container.layoutIfNeeded()
        let overlay = try XCTUnwrap(
            phase7View(with: "terminal-dpad-overlay", in: bar)
        )

        // Drag the card to the far right of the 400pt layout.
        bar.moveDPadOverlay(translation: CGPoint(x: 500, y: 0))
        container.layoutIfNeeded()
        XCTAssertGreaterThanOrEqual(overlay.frame.minX, 0)

        // Shrink to a 320pt layout: the stored offset must re-clamp so the
        // card stays inside the bar without breaking a constraint.
        container.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        container.setNeedsLayout()
        container.layoutIfNeeded()
        XCTAssertLessThanOrEqual(
            overlay.frame.maxX,
            bar.bounds.width + 0.5,
            "A width shrink must re-clamp the stored drag offset"
        )
    }

    func testKeyboardButtonTogglesFirstResponder() throws {
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

        // Keyboard hidden: the toggle must request first responder.
        let becomeBefore = terminalView.becomeFirstResponderRequestCount
        keyboardButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(
            terminalView.becomeFirstResponderRequestCount,
            becomeBefore + 1
        )

        // While the terminal holds focus, the same button must resign it.
        _ = terminalView.becomeFirstResponder()
        guard terminalView.isFirstResponder else {
            throw XCTSkip("Test host did not grant first-responder status")
        }
        let resignBefore = terminalView.resignFirstResponderRequestCount
        keyboardButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(
            terminalView.resignFirstResponderRequestCount,
            resignBefore + 1
        )
    }

    func testCompositionHidesKeyboardToggleAndKeepsRowLayout() throws {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let terminalView = ShellTerminalView(frame: .zero)
        defer { terminalView.stop() }
        let bar = try XCTUnwrap(terminalView.shortcutBar)
        container.addSubview(bar)
        bar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 44)
        ])
        container.layoutIfNeeded()
        let keyboardButton = try XCTUnwrap(
            phase7View(with: "terminal-shortcut-dismiss-keyboard", in: bar)
                as? UIButton
        )
        XCTAssertFalse(keyboardButton.isHidden)

        bar.updateComposition(markedText: "nihao")
        container.layoutIfNeeded()
        XCTAssertTrue(
            keyboardButton.isHidden,
            "The keyboard toggle must hide while IME text is marked"
        )
        for button in phase7Buttons(in: bar) where !button.isHidden {
            XCTAssertLessThan(
                button.bounds.width,
                bar.bounds.width,
                "No control may span the full row during composition"
            )
        }

        bar.updateComposition(markedText: nil)
        XCTAssertFalse(keyboardButton.isHidden)
    }

    func testShortcutBarUsesMaterialBackdrop() throws {
        let terminalView = ShellTerminalView(frame: .zero)
        defer { terminalView.stop() }
        let bar = try XCTUnwrap(terminalView.shortcutBar)
        let barBackdrop = bar.subviews
            .compactMap { $0 as? UIVisualEffectView }
            .first
        XCTAssertNotNil(
            barBackdrop,
            "The bar must carry a glass/material backdrop"
        )
        XCTAssertNotNil(barBackdrop?.effect)
        XCTAssertEqual(bar.intrinsicContentSize.height, 44)
    }

    func testDPadOverlayDragStaysWithinBarBounds() throws {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let terminalView = ShellTerminalView(frame: .zero)
        defer { terminalView.stop() }
        let bar = try XCTUnwrap(terminalView.shortcutBar)
        container.addSubview(bar)
        bar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 44)
        ])
        container.layoutIfNeeded()
        let dpadButton = try XCTUnwrap(
            phase7View(with: "terminal-shortcut-dpad", in: bar) as? UIButton
        )
        dpadButton.sendActions(for: .touchUpInside)
        container.layoutIfNeeded()
        let overlay = try XCTUnwrap(
            phase7View(with: "terminal-dpad-overlay", in: bar)
        )
        XCTAssertFalse(overlay.isHidden)

        bar.moveDPadOverlay(translation: CGPoint(x: 500, y: 30))
        container.layoutIfNeeded()
        XCTAssertLessThanOrEqual(
            overlay.frame.maxX,
            bar.bounds.width + 0.5,
            "Dragging right must clamp at the bar's trailing edge"
        )

        bar.moveDPadOverlay(translation: CGPoint(x: -2000, y: 0))
        container.layoutIfNeeded()
        XCTAssertGreaterThanOrEqual(
            overlay.frame.minX,
            0,
            "Dragging left must clamp at the bar's leading edge"
        )
    }
}
