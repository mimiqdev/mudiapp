import Foundation
import UIKit
import XCTest
@testable import Mudi

@MainActor
final class Phase4TerminalInteractionTests: XCTestCase {
    func testRecordedFullFrameDecodesItsRealAnsiScreenSnapshot() throws {
        let frame = try HerdrTerminalControlCodec.decodeFrame(
            Data(Phase4HerdrTerminalFixtures.observedFullFrame.utf8)
        )

        XCTAssertTrue(frame.full)
        XCTAssertEqual(frame.encoding, "ansi")
        XCTAssertEqual(frame.width, 20)
        XCTAssertEqual(frame.height, 5)
        XCTAssertEqual(frame.sequence, 1)
        XCTAssertTrue(frame.bytes.starts(with: [0x1b, 0x5b]))
    }

    func testScrollCommandUsesTheObservedHerdrDirectionAndLinesFields() throws {
        let encoded = try HerdrTerminalControlCodec.encodeScroll(
            direction: .up,
            lines: 3
        )
        XCTAssertEqual(encoded.last, 0x0a)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        XCTAssertEqual(object["type"] as? String, "terminal.scroll")
        XCTAssertEqual(object["direction"] as? String, "up")
        XCTAssertEqual(object["lines"] as? Int, 3)
    }

    func testDefaultSwiftTermSizeStillInstallsSymbolsCascade() {
        let terminalView = ShellTerminalView(frame: .zero)

        terminalView.updateFontSize(12)

        XCTAssertTrue(TerminalFont.hasSymbolsCascade(in: terminalView.font))
        terminalView.stop()
    }

    func testRemoteScrollPanPreemptsCompetingPanWithoutSimultaneousRecognition() {
        let terminalView = ShellTerminalView(frame: .zero)
        let remotePan = UIPanGestureRecognizer()
        let mousePan = UIPanGestureRecognizer()
        terminalView.remoteScrollGesture = remotePan
        terminalView.remoteScrollbackEnabled = true

        XCTAssertTrue(
            terminalView.gestureRecognizer(
                remotePan,
                shouldBeRequiredToFailBy: mousePan
            )
        )
        XCTAssertFalse(
            terminalView.gestureRecognizer(
                remotePan,
                shouldRecognizeSimultaneouslyWith: mousePan
            )
        )
        terminalView.stop()
    }
}
