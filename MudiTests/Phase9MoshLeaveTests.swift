import Foundation
import HerdrKit
import XCTest
@testable import Mudi

final class Phase9MoshLeaveTests: XCTestCase {
    /// Captured from live mosh-server 1.4.0 `new -s -- /usr/bin/true`:
    /// stdout is only MOSH CONNECT; stderr has the detached pid line.
    private static let realMoshServerCombinedOutput = """
    Warning: SSH_CONNECTION not found; binding to any interface.

    mosh-server (mosh 1.4.0) [build mosh 1.4.0]
    Copyright 2012 Keith Winstein <mosh-devel@mit.edu>
    License GPLv3+: GNU GPL version 3 or later <http://gnu.org/licenses/gpl.html>.
    This is free software: you are free to change and redistribute it.
    There is NO WARRANTY, to the extent permitted by law.

    [mosh-server detached, pid = 95522]
    MOSH CONNECT 60001 GE0sKFO189zPL+rA0/xACg
    """

    func testMoshServerDaemonPidParsesRealStderrLine() {
        XCTAssertEqual(
            MoshServerDaemonPid.parse(from: Self.realMoshServerCombinedOutput),
            95522
        )
        XCTAssertEqual(
            MoshServerDaemonPid.parse(
                from: "[mosh-server detached, pid = 97255]\n"
            ),
            97255
        )
    }

    func testMoshServerDaemonPidRejectsFakePidEqualsString() {
        let fake = """
        MOSH CONNECT 60023 aaaaaaaaaaaaaaaaaaaaaa
        mosh-server pid=4112
        """
        XCTAssertNil(MoshServerDaemonPid.parse(from: fake))
        XCTAssertNil(MoshServerDaemonPid.parse(from: "mosh-server pid=4112"))
        XCTAssertNil(
            MoshServerDaemonPid.parse(
                from: "MOSH CONNECT 60001 GE0sKFO189zPL+rA0/xACg\n"
            )
        )
    }

    func testMoshServerCommandMergesStderrIntoTheLoginShell() {
        let login = SwiftMoshAdapter.serverCommand(for: nil)
        XCTAssertTrue(
            login.contains("mosh-server new -s 2>&1"),
            "Login-shell mosh-server must merge stderr so the pid line is captured"
        )
        let attach = SwiftMoshAdapter.serverCommand(
            for: "exec herdr terminal attach term_65a1d4135cfa21 --takeover"
        )
        XCTAssertTrue(attach.contains("2>&1"))
        XCTAssertTrue(attach.contains("mosh-server new -s --"))
        XCTAssertFalse(attach.contains("herdr terminal attach --takeover"))
    }

    func testMoshPaneLeaveKillsCapturedDaemonPidThenStopsLocalPTY() async throws {
        let releaseOrder = TestMoshReleaseOrder()
        let bootstrapChannel = TestRecordingInteractiveSSHChannel(
            releaseOrder: releaseOrder
        )
        let bootstrapSession = SSHShellSession(connectedChannel: bootstrapChannel)
        let moshTransport = TestRecordingMoshTransport(
            releaseOrder: releaseOrder
        )
        let transport = MoshHerdrTerminalTransport(
            session: bootstrapSession,
            host: phase4Host(),
            credentialsProvider: { phase2Credentials() },
            moshTransport: moshTransport
        )
        let pane = Pane(
            id: "w55:p1",
            title: "Mosh pane",
            terminalID: "term_65a1d4135cfa21"
        )

        try await transport.attach(to: pane)
        let createdPTYs = await moshTransport.getCreatedPTYs()
        let attachedPTY = try XCTUnwrap(createdPTYs.first)
        let execBeforeLeave = await bootstrapChannel.execCommands()
        XCTAssertTrue(
            execBeforeLeave.isEmpty,
            "Entering a pane must not kill a previous login-shell mosh-server"
        )
        let interactiveBeforeLeave = await bootstrapChannel.commands()
        XCTAssertTrue(
            interactiveBeforeLeave.isEmpty,
            "Pane enter must not open session-control"
        )

        await transport.releaseControl(for: pane.id)

        let interactiveAfterLeave = await bootstrapChannel.commands()
        XCTAssertTrue(
            interactiveAfterLeave.isEmpty,
            "Leave must not use session control --takeover"
        )
        let execCommands = await bootstrapChannel.execCommands()
        let killCommand = try XCTUnwrap(execCommands.first)
        XCTAssertTrue(killCommand.contains("kill -TERM 95522"))
        XCTAssertFalse(killCommand.contains("pkill"))
        XCTAssertFalse(killCommand.contains("session control"))
        XCTAssertEqual(execCommands.count, 1)
        let events = await releaseOrder.events()
        XCTAssertEqual(
            events,
            [.killSent, .moshPTYClosed],
            "Leave must TERM the captured daemon pid before local Mosh stop"
        )
        let attachedPTYIsClosed = await attachedPTY.getIsClosed()
        XCTAssertTrue(attachedPTYIsClosed)
        let terminalSession = await transport.terminalSession()
        XCTAssertNil(terminalSession)
    }

    func testMoshPaneLeaveWithoutPidDoesNotSearchOrUseSessionControl() async throws {
        let bootstrapChannel = TestRecordingInteractiveSSHChannel()
        let bootstrapSession = SSHShellSession(connectedChannel: bootstrapChannel)
        let moshTransport = TestRecordingMoshTransport(
            recordsPaneDaemonPid: false
        )
        let transport = MoshHerdrTerminalTransport(
            session: bootstrapSession,
            host: phase4Host(),
            credentialsProvider: { phase2Credentials() },
            moshTransport: moshTransport
        )
        let pane = Pane(
            id: "w55:p1",
            title: "Mosh pane",
            terminalID: "term_65a1d4135cfa21"
        )

        try await transport.attach(to: pane)
        await transport.releaseControl(for: pane.id)

        let interactiveCommands = await bootstrapChannel.commands()
        let execCommands = await bootstrapChannel.execCommands()
        XCTAssertTrue(interactiveCommands.isEmpty)
        XCTAssertTrue(
            execCommands.isEmpty,
            "No captured pid means failed Leave: no kill, no pkill, no session control"
        )
        let createdPTYs = await moshTransport.getCreatedPTYs()
        let attachedPTY = try XCTUnwrap(createdPTYs.first)
        let attachedPTYIsClosed = await attachedPTY.getIsClosed()
        XCTAssertTrue(attachedPTYIsClosed)
        let terminalSession = await transport.terminalSession()
        XCTAssertNil(terminalSession)
    }
}
