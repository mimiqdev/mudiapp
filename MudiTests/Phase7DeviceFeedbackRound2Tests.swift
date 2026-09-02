import HerdrKit
import SwiftUI
import UIKit
import XCTest
@preconcurrency import SwiftTerm
@testable import Mudi

/// Physical-device feedback round 2: D-pad popover placement and drag
/// direction, uniform bar icon configuration, and Shift-key-style latch
/// rendering.
@MainActor
final class Phase7DeviceFeedbackRound2Tests: XCTestCase {
    func testDPadOverlayPopsAboveBarNearDirectionButton() throws {
        let fixture = try makeBarFixture(width: 390)
        defer { fixture.teardown() }

        let dpadButton = try XCTUnwrap(
            phase7View(with: "terminal-shortcut-dpad", in: fixture.bar) as? UIButton
        )
        dpadButton.sendActions(for: .touchUpInside)
        fixture.container.layoutIfNeeded()
        let overlay = try XCTUnwrap(
            phase7View(with: "terminal-dpad-overlay", in: fixture.bar)
        )
        XCTAssertFalse(overlay.isHidden)

        // Popover semantics: the card arises just above the bar (its bottom
        // edge sits 12pt above the bar's top) near the direction button.
        XCTAssertLessThanOrEqual(
            overlay.frame.maxY,
            0,
            "The D-pad card must float above the shortcut bar"
        )
        XCTAssertLessThanOrEqual(
            abs(overlay.frame.minX - dpadButton.frame.minX),
            24,
            "The D-pad card must pop up near the direction button"
        )
    }

    func testDPadDragTracksFingerDirection() throws {
        let fixture = try makeBarFixture(width: 390)
        defer { fixture.teardown() }

        let dpadButton = try XCTUnwrap(
            phase7View(with: "terminal-shortcut-dpad", in: fixture.bar) as? UIButton
        )
        dpadButton.sendActions(for: .touchUpInside)
        fixture.container.layoutIfNeeded()
        let overlay = try XCTUnwrap(
            phase7View(with: "terminal-dpad-overlay", in: fixture.bar)
        )
        let initialMinX = overlay.frame.minX
        let initialMinY = overlay.frame.minY

        // Dragging left must move the card left.
        fixture.bar.moveDPadOverlay(translation: CGPoint(x: -40, y: 0))
        fixture.bar.layoutIfNeeded()
        XCTAssertLessThan(
            overlay.frame.minX,
            initialMinX,
            "Dragging left must move the card left"
        )

        // Dragging up must move the card up (away from the bar anchor).
        fixture.bar.moveDPadOverlay(translation: CGPoint(x: 0, y: -40))
        fixture.bar.layoutIfNeeded()
        XCTAssertLessThan(
            overlay.frame.minY,
            initialMinY,
            "Dragging up must move the card up"
        )
    }

    func testLatchRenderingTintsGlyphWithoutBackgroundFill() throws {
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
        let dpadButton = try XCTUnwrap(
            phase7View(with: "terminal-shortcut-dpad", in: bar) as? UIButton
        )

        controlButton.sendActions(for: .touchUpInside)
        XCTAssertTrue(controlButton.isSelected)
        XCTAssertEqual(
            controlButton.backgroundColor,
            .clear,
            "Latched Ctrl must not fill the button background"
        )
        XCTAssertEqual(
            controlButton.tintColor,
            .systemBlue,
            "Latched Ctrl must tint the glyph with the accent color"
        )

        controlButton.sendActions(for: .touchUpInside)
        XCTAssertFalse(controlButton.isSelected)
        XCTAssertEqual(controlButton.tintColor, UIColor.label)

        dpadButton.sendActions(for: .touchUpInside)
        XCTAssertTrue(dpadButton.isSelected)
        XCTAssertEqual(dpadButton.backgroundColor, .clear)
        XCTAssertEqual(dpadButton.tintColor, .systemBlue)

        dpadButton.sendActions(for: .touchUpInside)
        XCTAssertFalse(dpadButton.isSelected)
        XCTAssertEqual(dpadButton.tintColor, UIColor.label)
        _ = dpadButton
    }

    func testBarIconsShareUniformSymbolConfiguration() throws {
        let terminalView = ShellTerminalView(frame: .zero)
        let harness = Phase7TerminalViewHarness(terminalView: terminalView)
        defer {
            harness.close()
            terminalView.stop()
        }
        let bar = try XCTUnwrap(terminalView.shortcutBar)
        harness.window.layoutIfNeeded()
        let buttons = phase7ShortcutButtons(in: bar)
        XCTAssertEqual(buttons.count, 7)

        // UIKit enriches stored symbol configurations with environment
        // traits, so uniformity + identical point size/weight/scale are
        // asserted via the configuration descriptions.
        let descriptions = buttons.map {
            String(describing: $0.image(for: .normal)?.configuration)
        }
        for description in descriptions {
            XCTAssertTrue(description.contains("pointSize=15"), description)
            XCTAssertTrue(description.contains("weight=Semibold"), description)
            XCTAssertTrue(description.contains("scale=Medium"), description)
        }
        let heights = Set(buttons.map { $0.bounds.height })
        XCTAssertEqual(
            heights,
            [32],
            "All bar buttons must share one uniform frame height"
        )
    }

    @MainActor
    private struct BarFixture {
        let container: UIView
        let bar: MudiTerminalShortcutBar
        let terminalView: ShellTerminalView

        func teardown() {
            terminalView.stop()
        }
    }

    private func makeBarFixture(width: CGFloat) throws -> BarFixture {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: width, height: 240))
        let terminalView = ShellTerminalView(frame: .zero)
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
        return BarFixture(
            container: container,
            bar: bar,
            terminalView: terminalView
        )
    }
}
