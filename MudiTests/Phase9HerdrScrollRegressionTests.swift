import Foundation
import HerdrKit
import TraversioMoshCore
import UIKit
import XCTest
@testable import Mudi

/// Regression coverage for the user-confirmed vertical-swipe scrolling
/// regression on the Mosh-backed Herdr pane attach path.
///
/// Phase 9 switched an attached Herdr pane from the SSH
/// `terminal session control` NDJSON stream (which answers `terminal.scroll`)
/// to a raw `herdr terminal attach` child inside a Mosh data session. The raw
/// Mosh session is a `PTYOutputChannel`-only channel, so
/// `supportsRemoteScrollback()` is false, `TerminalRemoteScrollback` never
/// installed a pan gesture, and the swipe fell through to SwiftTerm's local
/// (empty, frame-replaced) scrollback. The remote application is the only
/// scroll target left; it reports its mouse modes through the Traversio
/// snapshot bridge, so a vertical swipe must become terminal mouse-wheel
/// input for it.
@MainActor
final class Phase9HerdrScrollRegressionTests: XCTestCase {
    func testMoshRawAttachSessionInstallsRemoteScrollGesture() async throws {
        let attached = try await makeAttachedPaneSession()
        let terminalView = ShellTerminalView(frame: Self.terminalFrame)
        defer { terminalView.stop() }

        terminalView.start(session: attached.session, onError: { _ in })

        try await waitUntil("remote scroll gesture installed") {
            terminalView.remoteScrollGesture != nil
        }
        XCTAssertFalse(
            terminalView.isScrollEnabled,
            "A raw Mosh attach has no local scrollback to own the gesture"
        )
    }

    func testMoshRawAttachReportsWheelCapabilityWithoutHostScrollback() async throws {
        let attached = try await makeAttachedPaneSession()

        let capability = await attached.session.scrollCapability()
        XCTAssertEqual(capability, .remoteMouseWheel)
        let supportsScrollback = await attached.session.supportsRemoteScrollback()
        XCTAssertFalse(
            supportsScrollback,
            "Mosh data sessions must not be wrapped in HerdrControlChannel"
        )
    }

    func testLoginShellMoshSessionKeepsNoRemoteScrollCapability() async throws {
        let session = try await makeLoginShellSession()

        let capability = await session.scrollCapability()
        XCTAssertEqual(capability, .none)
        let supportsScrollback = await session.supportsRemoteScrollback()
        XCTAssertFalse(supportsScrollback)
    }

    /// The user-visible failure: a vertical swipe on the raw attach must reach
    /// the remote application as encoded wheel input instead of dying in the
    /// empty local scrollback (or degrading to a mouse drag).
    func testMoshRawAttachVerticalPanSendsEncodedMouseWheel() async throws {
        let attached = try await makeAttachedPaneSession()
        let terminalView = ShellTerminalView(frame: Self.terminalFrame)
        var errors: [String] = []
        defer { terminalView.stop() }
        terminalView.start(session: attached.session, onError: { errors.append($0) })

        try await waitUntil("remote scroll gesture installed") {
            terminalView.remoteScrollGesture != nil
        }
        try await enableMouseReporting(in: attached.moshSession, terminalView: terminalView)

        let columnCount = terminalView.getTerminal().cols
        let lineHeight = terminalView.font.lineHeight
        let location = CGPoint(x: 60, y: 120)
        terminalView.handleRemoteScroll(
            state: .began,
            translationY: 0,
            velocityY: 0,
            location: location
        )
        terminalView.handleRemoteScroll(
            state: .changed,
            translationY: lineHeight * 2,
            velocityY: 0,
            location: location
        )
        terminalView.handleRemoteScroll(
            state: .ended,
            translationY: lineHeight * 2,
            velocityY: 0,
            location: location
        )

        try await waitUntil("two wheel events") {
            self.wheelEvents(in: await attached.moshSession.sentBytes()).count >= 2
        }
        let sent = await attached.moshSession.sentBytes()
        let wheelEvents = wheelEvents(in: sent)
        XCTAssertEqual(
            wheelEvents.count,
            2,
            "Each row of finger travel must become one wheel event"
        )
        for bytes in wheelEvents {
            let text = String(decoding: bytes, as: UTF8.self)
            XCTAssertTrue(
                text.hasPrefix("\u{1b}[<64;"),
                "Wheel up must use the SGR button 64 encoding, got \(text.debugDescription)"
            )
            XCTAssertTrue(text.hasSuffix("M"))
        }
        XCTAssertFalse(
            sent.contains { String(decoding: $0, as: UTF8.self).hasPrefix("\u{1b}[<0;") },
            "A vertical pan must not become a mouse drag event"
        )
        XCTAssertGreaterThan(columnCount, 0)
        XCTAssertTrue(
            errors.isEmpty,
            "Wheel routing must not fall back to host scrollback errors: \(errors)"
        )
    }

    /// Without mouse reporting there is no wheel target; the gesture must
    /// decline so SwiftTerm keeps owning the touch and no escape garbage is
    /// sent to the application.
    func testMoshRawAttachGestureDeclinesWithoutMouseReporting() async throws {
        let attached = try await makeAttachedPaneSession()
        let terminalView = ShellTerminalView(frame: Self.terminalFrame)
        defer { terminalView.stop() }
        terminalView.start(session: attached.session, onError: { _ in })

        try await waitUntil("remote scroll gesture installed") {
            terminalView.remoteScrollGesture != nil
        }
        XCTAssertEqual(terminalView.getTerminal().mouseMode, .off)

        let pan = StubVelocityPanGestureRecognizer()
        pan.stubbedVelocity = CGPoint(x: 0, y: 220)
        terminalView.remoteScrollGesture = pan
        XCTAssertFalse(
            terminalView.gestureRecognizerShouldBegin(pan),
            "Without mouse reporting the attached app must not receive wheel input"
        )

        let lineHeight = terminalView.font.lineHeight
        terminalView.handleRemoteScroll(
            state: .began,
            translationY: 0,
            velocityY: 0,
            location: .zero
        )
        terminalView.handleRemoteScroll(
            state: .changed,
            translationY: lineHeight * 3,
            velocityY: 0,
            location: .zero
        )
        try await Task.sleep(for: .milliseconds(50))
        let sent = await attached.moshSession.sentBytes()
        XCTAssertTrue(sent.isEmpty)
    }

    func testMoshRawAttachVerticalPanOwnsGestureAgainstMouseReporter() async throws {
        let attached = try await makeAttachedPaneSession()
        let terminalView = ShellTerminalView(frame: Self.terminalFrame)
        defer { terminalView.stop() }
        terminalView.start(session: attached.session, onError: { _ in })

        try await waitUntil("remote scroll gesture installed") {
            terminalView.remoteScrollGesture != nil
        }
        let pan = StubVelocityPanGestureRecognizer()
        pan.stubbedVelocity = CGPoint(x: 0, y: 220)
        terminalView.remoteScrollGesture = pan

        XCTAssertFalse(
            terminalView.gestureRecognizerShouldBegin(pan),
            "No wheel input exists before the app enables mouse reporting"
        )

        try await enableMouseReporting(in: attached.moshSession, terminalView: terminalView)
        XCTAssertTrue(
            terminalView.gestureRecognizerShouldBegin(pan),
            "A vertical pan must own the gesture while mouse reporting is on"
        )

        let mouseReporterPan = UIPanGestureRecognizer()
        XCTAssertTrue(
            terminalView.gestureRecognizer(
                pan,
                shouldBeRequiredToFailBy: mouseReporterPan
            ),
            "SwiftTerm's mouse reporter must wait for the vertical-pan decision"
        )
        XCTAssertFalse(
            terminalView.gestureRecognizer(
                pan,
                shouldRecognizeSimultaneouslyWith: mouseReporterPan
            ),
            "A pan must never be both wheel input and a mouse drag"
        )

        pan.stubbedVelocity = CGPoint(x: 220, y: 0)
        XCTAssertFalse(
            terminalView.gestureRecognizerShouldBegin(pan),
            "Horizontal pans stay with SwiftTerm"
        )
    }

    // MARK: - Harness

    static let terminalFrame = CGRect(x: 0, y: 0, width: 320, height: 480)

    private func makeAttachedPaneSession() async throws
        -> (session: SSHShellSession, moshSession: TestTraversioMoshSession) {
        let (session, moshSession) = try await makeMoshSession(
            command: "exec herdr terminal attach term_65a1d4135cfa21 --takeover"
        )
        return (session, moshSession)
    }

    private func makeLoginShellSession() async throws -> SSHShellSession {
        let (session, _) = try await makeMoshSession(command: nil)
        return session
    }

    private func makeMoshSession(
        command: String?
    ) async throws -> (session: SSHShellSession, moshSession: TestTraversioMoshSession) {
        let bootstrap = TestMoshBootstrapChannel(
            output: Array(Self.bootstrapOutput.utf8)
        )
        let bootstrapSession = SSHShellSession(connectedChannel: bootstrap)
        let box = MoshSessionBox()
        let adapter = TraversioMoshAdapter(makeSession: { endpoint, dimensions in
            let session = TestTraversioMoshSession(
                endpoint: endpoint,
                dimensions: dimensions,
                snapshot: MoshTerminalScreen(dimensions: dimensions).snapshot
            )
            box.append(session)
            return session
        })

        let session = try await adapter.connect(
            to: phase9Host(),
            credentials: phase2Credentials(),
            using: bootstrapSession,
            command: command
        )
        let moshSession = try XCTUnwrap(box.first())
        return (session, moshSession)
    }

    /// Publishes the mouse modes `pi` enables (`1000`/`1002`/`1006`) through
    /// the snapshot bridge so the terminal starts encoding wheel input.
    private func enableMouseReporting(
        in moshSession: TestTraversioMoshSession,
        terminalView: ShellTerminalView
    ) async throws {
        var screen = MoshTerminalScreen(
            dimensions: try MoshTerminalDimensions(columns: 80, rows: 24)
        )
        _ = try screen.apply(MoshTerminalOutput(
            bytes: Array(
                "\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1004h\u{1b}[?1006h".utf8
            )
        ))
        await moshSession.publish(
            .write(MoshTerminalOutput(bytes: [0x78])),
            snapshot: screen.snapshot
        )
        try await waitUntil("mouse reporting enabled") {
            terminalView.getTerminal().mouseMode != .off
        }
    }

    private func wheelEvents(in sent: [[UInt8]]) -> [[UInt8]] {
        sent.filter {
            String(decoding: $0, as: UTF8.self).hasPrefix("\u{1b}[<")
        }
    }

    private static let bootstrapOutput = """
    Warning: SSH_CONNECTION not found; binding to any interface.

    [mosh-server detached, pid = 95522]
    MOSH CONNECT 60001 GE0sKFO189zPL+rA0/xACg

    """

    private func waitUntil(
        _ description: String,
        timeoutSeconds: Double = 2,
        _ condition: @MainActor () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        struct ConditionTimeout: Error, CustomStringConvertible {
            let message: String
            var description: String { message }
        }
        throw ConditionTimeout(message: "ConditionTimeout waiting for \(description)")
    }
}

/// A pan recognizer whose velocity can be stubbed: UIKit owns the real state
/// transition, but the vertical/horizontal decision reads velocity.
private final class StubVelocityPanGestureRecognizer: UIPanGestureRecognizer {
    var stubbedVelocity = CGPoint.zero

    override func velocity(in view: UIView?) -> CGPoint {
        stubbedVelocity
    }
}
