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
/// installs a pan gesture, and the swipe falls through to SwiftTerm's local
/// (empty, frame-replaced) scrollback. The remote application is the only
/// scroll target left; it already reports its mouse modes through the
/// Traversio snapshot bridge, so a vertical swipe must become terminal
/// mouse-wheel input for it.
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

    // MARK: - Harness

    static let terminalFrame = CGRect(x: 0, y: 0, width: 320, height: 480)

    private func makeAttachedPaneSession() async throws -> (session: SSHShellSession, moshSession: TestTraversioMoshSession) {
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
            command: "exec herdr terminal attach term_65a1d4135cfa21 --takeover"
        )
        let moshSession = try XCTUnwrap(box.first())
        return (session, moshSession)
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
