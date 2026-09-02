import HerdrKit
import UIKit
import XCTest
@preconcurrency import SwiftTerm
@testable import Mudi

@MainActor
final class Phase8LiveFontTests: XCTestCase {
    func testLiveFontSizeChangePreservesApplicationCursorMode() async {
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

        terminalView.updateFont(
            familyName: TerminalFontRegistry.defaultFamilyName,
            pointSize: 14
        )
        terminalView.start(session: session, onError: { _ in })
        harness.window.layoutIfNeeded()
        await Task.yield()
        harness.window.layoutIfNeeded()

        terminalView.getTerminal().applicationCursor = true
        terminalView.updateFontSize(16)
        harness.window.layoutIfNeeded()

        XCTAssertEqual(terminalView.font.pointSize, 16, accuracy: 0.001)
        XCTAssertTrue(
            terminalView.getTerminal().applicationCursor,
            "Changing the live font must not send a DECSTR soft reset"
        )
    }
}
