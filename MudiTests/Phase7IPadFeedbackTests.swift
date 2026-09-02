import HerdrKit
import SwiftUI
import UIKit
import XCTest
@preconcurrency import SwiftTerm
@testable import Mudi

/// Physical-device feedback (iPad): the Herdr Picker popover anchors to the
/// top toolbar area instead of floating centered, the IME composition strip
/// is suppressed on iPad, and the terminal grid keeps a small horizontal
/// inset from the bezels.
@MainActor
final class Phase7IPadFeedbackTests: XCTestCase {
    // MARK: 1 - Picker presentation policy (single sheet, both idioms)

    func testSheetPolicyIdenticalForBothIdiomsWithCenteredWidthCap() {
        // One sheet policy for iPhone and iPad: medium/large detents,
        // visible drag indicator, native interactive dismissal.
        let policy = PanePickerPresentationPolicy.compactSheet
        XCTAssertEqual(policy.compactDetents, [.medium, .large])
        XCTAssertTrue(policy.showsDragIndicator)
        XCTAssertTrue(policy.usesSystemInteractiveDismissal)

        // iPad adds the centered content-capped width (reusing the
        // existing cap): 420pt landscape / 320pt portrait.
        XCTAssertEqual(
            PanePickerPresentationPolicy.popoverContentWidth(for: 1180),
            420
        )
        XCTAssertEqual(
            PanePickerPresentationPolicy.popoverContentWidth(for: 820),
            320
        )
    }

    // MARK: 2 - composition strip idiom gating

    func testCompositionStripSuppressionKeepsRowLayout() throws {
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
        let label = try XCTUnwrap(
            phase7View(with: "terminal-ime-composition", in: bar)
        )

        func visibleButtons() -> [UIButton] {
            phase7ShortcutButtons(in: bar).filter { !$0.isHidden }
        }

        // Baseline on a software-keyboard idiom: the strip is active.
        bar.isCompositionStripSuppressed = false
        bar.updateComposition(markedText: "ceshi biaoji")
        harness.window.layoutIfNeeded()
        XCTAssertFalse(label.isHidden)
        XCTAssertTrue(visibleButtons().isEmpty)

        // Suppressed (iPad idiom): the marked-text pill stays hidden, but
        // the LAYOUT behavior is idiom-independent - the keyboard toggle
        // and shortcut buttons still hide while composing.
        bar.isCompositionStripSuppressed = true
        bar.updateComposition(markedText: "ceshi biaoji")
        harness.window.layoutIfNeeded()
        XCTAssertTrue(
            label.isHidden,
            "The suppressed composition strip must stay hidden"
        )
        XCTAssertTrue(
            keyboardButton.isHidden,
            "The keyboard toggle must hide during composition on iPad too"
        )
        XCTAssertTrue(
            visibleButtons().isEmpty,
            "No control may span the full row during composition"
        )

        // Ending the composition restores the row exactly.
        bar.updateComposition(markedText: nil)
        harness.window.layoutIfNeeded()
        XCTAssertFalse(keyboardButton.isHidden)
        XCTAssertEqual(visibleButtons().count, 7)
        XCTAssertTrue(
            label.isHidden,
            "A suppressed strip must never present the composition label"
        )
    }

    // MARK: 3 - terminal horizontal inset policy

    func testTerminalViewIsHorizontallyInset() async throws {
        let harness = Phase7TerminalScreenHarness(
            host: phase2Host(),
            session: SSHShellSession(connectedChannel: Phase4OutputChannel()),
            onDisconnect: {},
            onBackToBrowser: {},
            onOpenPanePicker: {}
        )
        defer { harness.close() }

        var terminal: ShellTerminalView?
        for _ in 0..<100 {
            terminal = await harness.terminal()
            if terminal != nil { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let terminalView = try XCTUnwrap(terminal)
        XCTAssertEqual(
            TerminalHorizontalInsetPolicy.standard.horizontalInset,
            6
        )
        let windowView = try XCTUnwrap(terminalView.window)
        let frameInWindow = terminalView.convert(
            terminalView.bounds,
            to: windowView
        )
        let inset = TerminalHorizontalInsetPolicy.standard.horizontalInset
        XCTAssertGreaterThanOrEqual(
            frameInWindow.minX,
            inset - 0.5,
            "The terminal grid must not touch the leading bezel"
        )
        XCTAssertLessThanOrEqual(
            frameInWindow.maxX,
            windowView.bounds.width - inset + 0.5,
            "The terminal grid must not touch the trailing bezel"
        )
    }
}
