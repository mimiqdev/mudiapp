import HerdrKit
import SwiftUI
import UIKit
import XCTest
@preconcurrency import SwiftTerm
@testable import Mudi

/// Capsule layout contract for the floating shortcut bar: iPhone expands
/// to nearly the full width with small margins, iPad centers a
/// content-capped capsule, corners are fully rounded, and the bar applies
/// the resolved geometry.
@MainActor
final class Phase7CapsuleBarTests: XCTestCase {
    // MARK: policy resolution

    func testPolicyResolvesByHorizontalSizeClass() {
        let compact = UITraitCollection(horizontalSizeClass: .compact)
        let regular = UITraitCollection(horizontalSizeClass: .regular)
        XCTAssertEqual(
            MudiShortcutBarCapsulePolicy.resolved(for: compact),
            .phone
        )
        XCTAssertEqual(
            MudiShortcutBarCapsulePolicy.resolved(for: regular),
            .pad
        )
    }

    // MARK: iPhone layout contract

    func testPhonePolicyExpandsToNearlyFullWidthWithMargins() {
        let layout = MudiShortcutBarCapsulePolicy.phone.capsuleLayout(
            containerWidth: 390,
            barHeight: 44
        )
        XCTAssertEqual(
            layout.width,
            390 - 2 * MudiShortcutBarCapsulePolicy.phone.horizontalMargin,
            "iPhone must expand the capsule to nearly the full width"
        )
        XCTAssertFalse(
            layout.centered,
            "The expanded iPhone capsule must span margin to margin"
        )
        XCTAssertEqual(
            layout.cornerRadius,
            22,
            "A 44pt bar must have fully rounded capsule corners"
        )
        XCTAssertEqual(layout.bottomMargin, 10)
    }

    // MARK: iPad layout contract

    func testPadPolicyCentersContentCappedCapsule() {
        let layout = MudiShortcutBarCapsulePolicy.pad.capsuleLayout(
            containerWidth: 800,
            barHeight: 44
        )
        XCTAssertEqual(
            layout.width,
            MudiShortcutBarCapsulePolicy.pad.maxContentWidth,
            "iPad must cap the capsule width instead of spanning"
        )
        XCTAssertTrue(
            layout.centered,
            "The capped iPad capsule must be centered"
        )
        XCTAssertEqual(layout.cornerRadius, 22)
    }

    func testPadPolicyFallsBackToFullSpanWhenCapNoLongerBinds() {
        // A narrow regular-width layout (split view) where the margins
        // bind before the content cap: the capsule spans margin to margin.
        let containerWidth: CGFloat = 460
        let layout = MudiShortcutBarCapsulePolicy.pad.capsuleLayout(
            containerWidth: containerWidth,
            barHeight: 44
        )
        XCTAssertEqual(
            layout.width,
            containerWidth - 2 * MudiShortcutBarCapsulePolicy.pad.horizontalMargin
        )
        XCTAssertFalse(layout.centered)
    }

    // MARK: r11-f1 - mode re-evaluation on same-class widening

    func testCapsuleModeRecentersWhenRegularLayoutWidens() throws {
        // The container must be attached to a window for trait overrides
        // to propagate to the bar.
        let window = Phase7TerminalScreenHarness.makeWindow()
        defer { window.isHidden = true }
        let container = UIView(
            frame: CGRect(x: 0, y: 0, width: 460, height: 240)
        )
        window.addSubview(container)
        window.makeKeyAndVisible()
        let terminalView = ShellTerminalView(frame: .zero)
        defer { terminalView.stop() }
        let bar = try XCTUnwrap(terminalView.shortcutBar)
        container.addSubview(bar)
        bar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bar.heightAnchor.constraint(
                equalToConstant: ShellTerminalView.shortcutBarHeight
            )
        ])
        bar.traitOverrides.horizontalSizeClass = .regular
        bar.applyCapsuleLayout(.pad, in: container)
        container.setNeedsLayout()
        container.layoutIfNeeded()

        // A regular-width layout that starts below the cap threshold falls
        // back to the margin-span mode (460 - 2 x 12 = 436pt).
        let spanWidth = container.bounds.width
            - 2 * MudiShortcutBarCapsulePolicy.pad.horizontalMargin
        XCTAssertEqual(
            bar.frame.width,
            spanWidth,
            accuracy: 0.5,
            "Below the cap threshold the capsule must span margin to margin"
        )

        // ...and widening past the threshold must re-center the capped
        // capsule instead of staying sticky in the span mode.
        container.frame = CGRect(x: 0, y: 0, width: 800, height: 240)
        container.setNeedsLayout()
        container.layoutIfNeeded()
        bar.layoutIfNeeded()
        let layout = MudiShortcutBarCapsulePolicy.pad.capsuleLayout(
            containerWidth: container.bounds.width,
            barHeight: ShellTerminalView.shortcutBarHeight
        )
        XCTAssertEqual(
            bar.frame.width,
            layout.width,
            accuracy: 0.5,
            "Widening past the cap threshold must re-cap the capsule"
        )
        XCTAssertEqual(
            bar.frame.midX,
            container.bounds.midX,
            accuracy: 0.5,
            "The re-capped capsule must be centered"
        )
    }

    // MARK: applied geometry on the bar

    func testBarAppliesPhoneCapsuleGeometry() throws {
        let container = UIView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 240)
        )
        let terminalView = ShellTerminalView(frame: .zero)
        defer { terminalView.stop() }
        let bar = try XCTUnwrap(terminalView.shortcutBar)
        container.addSubview(bar)
        bar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bar.bottomAnchor.constraint(
                equalTo: container.bottomAnchor,
                constant: -MudiShortcutBarCapsulePolicy.phone.bottomMargin
            ),
            bar.heightAnchor.constraint(
                equalToConstant: ShellTerminalView.shortcutBarHeight
            )
        ])
        bar.applyCapsuleLayout(.phone, in: container)
        container.layoutIfNeeded()

        let layout = MudiShortcutBarCapsulePolicy.phone.capsuleLayout(
            containerWidth: container.bounds.width,
            barHeight: ShellTerminalView.shortcutBarHeight
        )
        XCTAssertEqual(
            bar.frame.width,
            layout.width,
            accuracy: 0.5,
            "iPhone: the capsule spans margin to margin"
        )
        XCTAssertEqual(bar.frame.minX, layout.horizontalMargin, accuracy: 0.5)
        XCTAssertEqual(
            bar.frame.maxY,
            container.bounds.height
                - MudiShortcutBarCapsulePolicy.phone.bottomMargin,
            accuracy: 0.5,
            "iPhone: the capsule floats above the container bottom"
        )
        XCTAssertEqual(
            bar.layer.cornerRadius,
            layout.cornerRadius,
            accuracy: 0.5,
            "The capsule corners must be fully rounded"
        )
    }

    func testBarAppliesCenteredCappedCapsuleOnRegularWidth() throws {
        // The container must be attached to a window for trait overrides
        // to propagate to the bar.
        let window = Phase7TerminalScreenHarness.makeWindow()
        defer { window.isHidden = true }
        let container = UIView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 240)
        )
        window.addSubview(container)
        window.makeKeyAndVisible()
        let terminalView = ShellTerminalView(frame: .zero)
        defer { terminalView.stop() }
        let bar = try XCTUnwrap(terminalView.shortcutBar)
        container.addSubview(bar)
        bar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bar.heightAnchor.constraint(
                equalToConstant: ShellTerminalView.shortcutBarHeight
            )
        ])
        // Force the bar's own size class to regular (iPad).
        bar.traitOverrides.horizontalSizeClass = .regular
        bar.applyCapsuleLayout(.pad, in: container)
        container.setNeedsLayout()
        container.layoutIfNeeded()

        let layout = MudiShortcutBarCapsulePolicy.pad.capsuleLayout(
            containerWidth: container.bounds.width,
            barHeight: ShellTerminalView.shortcutBarHeight
        )
        XCTAssertEqual(
            bar.frame.width,
            layout.width,
            accuracy: 0.5,
            "iPad: the capsule width is content-capped"
        )
        XCTAssertEqual(
            bar.frame.midX,
            container.bounds.midX,
            accuracy: 0.5,
            "iPad: the capsule is centered"
        )
        XCTAssertGreaterThanOrEqual(bar.frame.minX, 12)
        XCTAssertLessThanOrEqual(bar.frame.maxX, 800 - 12)
    }
}
