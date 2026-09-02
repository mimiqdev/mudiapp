import Foundation
import HerdrKit
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

    func testTerminalErrorStateClearsOnSessionIdentityChange() {
        let firstSession = NSObject()
        let secondSession = NSObject()
        let firstIdentity = ObjectIdentifier(firstSession)
        let secondIdentity = ObjectIdentifier(secondSession)
        var state = TerminalSessionErrorState(
            sessionIdentity: firstIdentity
        )

        state.receive("The SSH shell connection was lost.", for: firstIdentity)
        XCTAssertEqual(state.message, "The SSH shell connection was lost.")

        state.updateSession(secondIdentity)
        XCTAssertNil(state.message)

        state.receive("stale error", for: firstIdentity)
        XCTAssertNil(state.message)
        XCTAssertEqual(state.sessionIdentity, secondIdentity)
    }

    func testTerminalStartAndSessionReplacementDoNotRequestFirstResponder() {
        let firstSession = SSHShellSession(
            connectedChannel: Phase4OutputChannel()
        )
        let secondSession = SSHShellSession(
            connectedChannel: Phase4OutputChannel()
        )
        let terminalView = ShellTerminalView(frame: .zero)

        terminalView.start(
            session: firstSession,
            onError: { _ in }
        )
        XCTAssertEqual(terminalView.becomeFirstResponderRequestCount, 0)

        terminalView.updateSession(
            session: secondSession,
            onError: { _ in }
        )
        XCTAssertEqual(terminalView.becomeFirstResponderRequestCount, 0)
        terminalView.stop()
    }

    func testTerminalStartRestoresFocusOnlyWhenKeyboardWasActive() async {
        let session = SSHShellSession(
            connectedChannel: Phase4OutputChannel()
        )
        let terminalView = ShellTerminalView(frame: .zero)
        terminalView.shouldRestoreInputFocus = true
        terminalView.start(
            session: session,
            onError: { _ in }
        )
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(terminalView.becomeFirstResponderRequestCount, 1)
        terminalView.stop()

        let inactiveSession = SSHShellSession(
            connectedChannel: Phase4OutputChannel()
        )
        let inactiveTerminalView = ShellTerminalView(frame: .zero)
        inactiveTerminalView.start(
            session: inactiveSession,
            onError: { _ in }
        )
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(inactiveTerminalView.becomeFirstResponderRequestCount, 0)
        inactiveTerminalView.stop()
    }

    func testFocusChangeCallbacksAndTeardownSuppression() {
        let session = SSHShellSession(
            connectedChannel: Phase4OutputChannel()
        )
        let terminalView = ShellTerminalView(frame: .zero)
        var focusChanges: [Bool] = []
        terminalView.onInputFocusChange = { focusChanges.append($0) }
        terminalView.start(
            session: session,
            onError: { _ in }
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        window.addSubview(terminalView)
        window.makeKeyAndVisible()

        _ = terminalView.becomeFirstResponder()
        _ = terminalView.resignFirstResponder()
        XCTAssertEqual(focusChanges, [true, false])

        // UIKit resigns first responder when a view leaves the window. That
        // implicit teardown resign must not report a user keyboard dismissal.
        _ = terminalView.becomeFirstResponder()
        terminalView.stop()
        _ = terminalView.resignFirstResponder()
        XCTAssertEqual(focusChanges, [true, false, true])
        terminalView.removeFromSuperview()
    }

    func testSuppressedTerminalInputResignsWithoutReacquiringAfterDismissal() {
        let session = SSHShellSession(
            connectedChannel: Phase4OutputChannel()
        )
        let terminalView = ShellTerminalView(frame: .zero)
        terminalView.start(
            session: session,
            onError: { _ in }
        )

        terminalView.updateInputFocus(isAllowed: false)
        XCTAssertFalse(terminalView.isInputFocusAllowed)
        XCTAssertEqual(terminalView.resignFirstResponderRequestCount, 1)
        let becomeRequestCount = terminalView.becomeFirstResponderRequestCount

        terminalView.updateInputFocus(isAllowed: true)
        XCTAssertTrue(terminalView.isInputFocusAllowed)
        XCTAssertEqual(
            terminalView.becomeFirstResponderRequestCount,
            becomeRequestCount
        )
        terminalView.stop()
    }

    func testNormalTerminalOutputCompletionUsesCloseCallbackNotError() async {
        let channel = Phase4OutputChannel()
        let session = SSHShellSession(connectedChannel: channel)
        let terminalView = ShellTerminalView(frame: .zero)
        let closeExpectation = expectation(description: "normal terminal close")
        var errors: [String] = []

        terminalView.start(
            session: session,
            onError: { errors.append($0) },
            onClosed: { closeExpectation.fulfill() }
        )
        await channel.finish()
        await fulfillment(of: [closeExpectation], timeout: 1)

        XCTAssertTrue(errors.isEmpty)
        terminalView.stop()
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
