import HerdrKit
import UIKit
import XCTest
@preconcurrency import SwiftTerm
@testable import Mudi

@MainActor
final class Phase8TerminalLayoutTests: XCTestCase {
    func testAppearanceAndKeyboardRelayoutKeepTerminalContentToWholeRows() async throws {
        let terminalView = ShellTerminalView(frame: .zero)
        let chromeView = TerminalChromeView(terminalView: terminalView)
        let harness = Phase7TerminalViewHarness(
            terminalView: terminalView,
            chromeView: chromeView
        )
        let session = SSHShellSession(connectedChannel: Phase8RecordingPTY())
        defer {
            terminalView.stop()
            harness.close()
        }

        let theme = try XCTUnwrap(
            TerminalThemeRegistry.theme(named: "Catppuccin Mocha")
        )
        terminalView.apply(theme: theme)
        terminalView.updateFont(
            familyName: TerminalFontRegistry.defaultFamilyName,
            pointSize: 22
        )
        terminalView.start(session: session, onError: { _ in })
        harness.window.layoutIfNeeded()
        await settleLayout(for: harness)

        assertWholeRowLayout(of: terminalView, label: "keyboard down")

        terminalView.updateShortcutBarOffset(
            keyboardFrameEnd: CGRect(x: 0, y: 400, width: 390, height: 444)
        )
        await settleLayout(for: harness)
        assertWholeRowLayout(of: terminalView, label: "keyboard up")

        terminalView.updateShortcutBarOffset(
            keyboardFrameEnd: CGRect(x: 0, y: 844, width: 390, height: 0)
        )
        await settleLayout(for: harness)
        assertWholeRowLayout(of: terminalView, label: "keyboard down again")

        terminalView.updateFontSize(14)
        await settleLayout(for: harness)
        assertWholeRowLayout(of: terminalView, label: "font changed after mount")
    }

    private func settleLayout(for harness: Phase7TerminalViewHarness) async {
        for _ in 0..<8 {
            harness.window.layoutIfNeeded()
            await Task.yield()
        }
    }

    private func assertWholeRowLayout(
        of terminalView: ShellTerminalView,
        label: String
    ) {
        let terminal = terminalView.getTerminal()
        let metrics = terminalView.terminalGridLayoutMetrics
        XCTAssertGreaterThan(metrics.rows, 0, "\(label) must have visible rows")
        XCTAssertEqual(
            terminal.rows,
            metrics.rows,
            "\(label) terminal rows must match the settled viewport"
        )
        XCTAssertEqual(
            metrics.contentHeight,
            CGFloat(metrics.rows) * metrics.cellHeight,
            accuracy: 0.001,
            "\(label) content height must be exactly rows × cell height"
        )
        XCTAssertGreaterThanOrEqual(
            terminalView.bounds.height + 0.001,
            metrics.contentHeight,
            "\(label) must not render beyond the current grid"
        )
        XCTAssertLessThan(
            metrics.trailingRemainder,
            metrics.cellHeight,
            "\(label) may leave less than one blank cell, never stale rows"
        )
        XCTAssertEqual(
            terminalView.contentSize.height,
            CGFloat(terminal.rows) * metrics.cellHeight,
            accuracy: 0.5,
            "\(label) fresh terminal content must not retain extra rows"
        )
    }
}
