import Foundation
import HerdrKit
import XCTest
@testable import Mudi

/// Regression coverage for a remote host whose `herdr` lives under the user's
/// home (mise shims on macmini). A noninteractive SSH login shell never runs
/// the interactive startup file that adds the shim directory to `PATH`, so
/// discovery reported "command not found" and the app showed "No Herdr
/// Sessions" while a saved machine profile and a running remote session
/// existed.
///
/// The fake channel models that login-shell contract: Herdr payloads are only
/// returned when the command body appends the standard user-local directories,
/// which is what the production command builder must do, and when a `herdr`
/// executable is actually installed.
final class Phase9HerdrBootstrapPathTests: XCTestCase {
    func testDiscoverySnapshotResolvesHerdrThroughTheLoginShellUserLocalPath() async throws {
        let channel = Phase9BootstrapCommandChannel(herdrInstalled: true)
        let discovery = SSHHerdrDiscovery(session: SSHShellSession(connectedChannel: channel))

        let snapshot = try await discovery.snapshot(for: phase4Host())

        XCTAssertEqual(snapshot.sessions.map(\.name), ["default"])
        XCTAssertEqual(snapshot.sessions.first?.workspaces.map(\.id), ["w1"])
        let commands = await channel.execCommands()
        XCTAssertEqual(commands.count, 4)
        guard commands.count == 4 else { return }
        for command in commands {
            XCTAssertTrue(
                command.contains(Phase9BootstrapCommandChannel.userLocalPathAppend),
                "Every Herdr command must append the user-local mise shim path: \(command)"
            )
        }
        XCTAssertTrue(
            commands[0].contains(
                "if command -v herdr >/dev/null 2>&1; then herdr session list --json; else exit 0; fi"
            )
        )
        XCTAssertTrue(commands[1].contains(#"herdr --session '\''default'\'' workspace list"#))
    }

    func testDiscoveryWithoutAnInstalledHerdrStillReportsNoSessions() async throws {
        let channel = Phase9BootstrapCommandChannel(herdrInstalled: false)
        let discovery = SSHHerdrDiscovery(session: SSHShellSession(connectedChannel: channel))

        let snapshot = try await discovery.snapshot(for: phase4Host())

        XCTAssertTrue(
            snapshot.sessions.isEmpty,
            "An absent herdr executable must still mean no Herdr sessions"
        )
        let commands = await channel.execCommands()
        XCTAssertEqual(
            commands.count,
            1,
            "The guarded session-list command must exit 0 without querying a session"
        )
        XCTAssertTrue(commands[0].contains("command -v herdr"))
    }

    func testDiscoveryDoesNotMaskInvalidJSON() async throws {
        let channel = Phase9BootstrapCommandChannel(
            herdrInstalled: true,
            sessionListResponse: "herdr: unexpected output"
        )
        let discovery = SSHHerdrDiscovery(session: SSHShellSession(connectedChannel: channel))

        do {
            _ = try await discovery.snapshot(for: phase4Host())
            XCTFail("Invalid Herdr output must not silently become an empty snapshot")
        } catch SSHHerdrDiscoveryError.invalidJSON {
            // Expected: the output contract keeps invalid JSON an error.
        }
    }

    func testWorkspaceCreationUsesTheLoginShellUserLocalPath() async throws {
        let channel = Phase9BootstrapCommandChannel(herdrInstalled: true)
        let discovery = SSHHerdrDiscovery(session: SSHShellSession(connectedChannel: channel))

        let creation = try await discovery.createWorkspace()

        XCTAssertEqual(creation.workspaceID, "w1")
        let commands = await channel.execCommands()
        let command = try XCTUnwrap(commands.first)
        XCTAssertEqual(commands.count, 1)
        XCTAssertTrue(command.contains(Phase9BootstrapCommandChannel.userLocalPathAppend))
        XCTAssertTrue(command.contains("herdr workspace create --no-focus"))
    }

    func testTakeoverAttachRunsHerdrWithTheLoginShellUserLocalPath() async throws {
        let channel = Phase9BootstrapCommandChannel(herdrInstalled: true)
        let transport = SSHHerdrTerminalTransport(
            session: SSHShellSession(connectedChannel: channel)
        )
        let pane = Pane(
            id: "w1:p1",
            title: "π - mudiapp",
            terminalID: "term_0123456789ab"
        )

        try await transport.attach(to: pane)

        let commands = await channel.commands()
        let command = try XCTUnwrap(commands.first)
        XCTAssertEqual(commands.count, 1)
        XCTAssertTrue(command.contains(Phase9BootstrapCommandChannel.userLocalPathAppend))
        XCTAssertTrue(
            command.contains(
                #"exec herdr terminal session control '\''w1:p1'\'' --takeover --cols 80 --rows 24"#
            )
        )
    }

    func testMoshAttachRunsHerdrWithTheLoginShellUserLocalPath() async throws {
        let channel = Phase9BootstrapCommandChannel(herdrInstalled: true)
        let bootstrapSession = SSHShellSession(connectedChannel: channel)
        let moshTransport = TestRecordingMoshTransport()
        let transport = MoshHerdrTerminalTransport(
            session: bootstrapSession,
            host: phase4Host(),
            credentialsProvider: { phase2Credentials() },
            moshTransport: moshTransport
        )
        let pane = Pane(
            id: "w1:p1",
            title: "π - mudiapp",
            terminalID: "term_0123456789ab"
        )

        try await transport.attach(to: pane)

        let calls = await moshTransport.getCalls()
        let command = try XCTUnwrap(calls.first?.command)
        XCTAssertTrue(command.contains(Phase9BootstrapCommandChannel.userLocalPathAppend))
        XCTAssertTrue(
            command.contains(
                #"exec herdr terminal attach '\''term_0123456789ab'\'' --takeover"#
            )
        )
    }

    func testMoshServerBootstrapResolvesThroughTheLoginShellUserLocalPath() {
        let command = TraversioMoshAdapter.serverCommand(for: nil)

        XCTAssertTrue(command.contains(Phase9BootstrapCommandChannel.userLocalPathAppend))
        XCTAssertTrue(command.contains("mosh-server new -s 2>&1"))
    }

    func testMoshAttachBootstrapsTheMoshServerLoginShell() {
        let command = TraversioMoshAdapter.serverCommand(
            for: "\"${SHELL:-/bin/sh}\" -lc 'exec herdr terminal attach'"
        )

        XCTAssertTrue(command.contains(Phase9BootstrapCommandChannel.userLocalPathAppend))
        XCTAssertTrue(command.contains("mosh-server new -s --"))
        XCTAssertTrue(command.contains("2>&1"))
    }
}

/// Models the remote noninteractive login shell for the discovery contract.
///
/// The command body must append the standard user-local directories for
/// `herdr` to resolve at all; without them the guarded discovery command exits
/// zero with no output, exactly like the reported macmini failure.
private actor Phase9BootstrapCommandChannel: PTYChannel,
    SSHCommandExecutingChannel,
    SSHInteractiveCommandChannel {
    static let userLocalPathAppend =
        #"PATH="$PATH:$HOME/.local/share/mise/shims:$HOME/.local/bin"; export PATH"#

    private let herdrInstalled: Bool
    private let sessionListResponse: String
    private let interactiveChannel = TestMoshPTY()
    private var recordedExecCommands: [String] = []
    private var recordedInteractiveCommands: [String] = []

    init(
        herdrInstalled: Bool,
        sessionListResponse: String = Phase9BootstrapPayloads.sessionList
    ) {
        self.herdrInstalled = herdrInstalled
        self.sessionListResponse = sessionListResponse
    }

    func execute(_ command: String) async throws -> [UInt8] {
        recordedExecCommands.append(command)
        guard herdrInstalled, command.contains(Self.userLocalPathAppend) else {
            return []
        }
        if command.contains("session list --json") {
            return Array(sessionListResponse.utf8)
        }
        if command.contains("workspace create --no-focus") {
            return Array(Phase9BootstrapPayloads.workspaceCreate.utf8)
        }
        if command.contains("workspace list") {
            return Array(Phase9BootstrapPayloads.workspaceList.utf8)
        }
        if command.contains("pane list") {
            return Array(Phase9BootstrapPayloads.paneList.utf8)
        }
        if command.contains("agent list") {
            return Array(Phase9BootstrapPayloads.agentList.utf8)
        }
        return []
    }

    func openInteractiveCommand(_ command: String) async throws -> any PTYOutputChannel {
        recordedInteractiveCommands.append(command)
        return interactiveChannel
    }

    func commands() -> [String] {
        recordedInteractiveCommands
    }

    func execCommands() -> [String] {
        recordedExecCommands
    }

    func send(_: [UInt8]) async throws {}

    func resize(columns _: Int, rows _: Int) async throws {}

    func close() async {}
}

/// Payloads recorded from `herdr 0.9.0`; volatile metadata and absolute paths
/// are trimmed the same way as the phase-3 fixtures, and the envelope keys are
/// exactly as the CLI emits them.
private enum Phase9BootstrapPayloads {
    static let sessionList = #"""
    {
      "sessions": [
        {
          "default": true,
          "name": "default",
          "running": true,
          "session_dir": "/recorded/herdr",
          "socket_path": "/recorded/herdr/herdr.sock"
        }
      ]
    }
    """#

    static let workspaceList = #"""
    {
      "id": "cli:workspace:list",
      "result": {
        "type": "workspace_list",
        "workspaces": [
          {
            "active_tab_id": "w1:t1",
            "agent_status": "idle",
            "focused": false,
            "label": "mudiapp",
            "number": 1,
            "pane_count": 1,
            "tab_count": 1,
            "workspace_id": "w1"
          }
        ]
      }
    }
    """#

    static let paneList = #"""
    {
      "id": "cli:pane:list",
      "result": {
        "type": "pane_list",
        "panes": [
          {
            "agent": "pi",
            "agent_status": "idle",
            "cwd": "/recorded/project",
            "focused": false,
            "foreground_cwd": "/recorded/project",
            "pane_id": "w1:p1",
            "revision": 1,
            "tab_id": "w1:t1",
            "terminal_id": "term_0123456789ab",
            "terminal_title_stripped": "π - mudiapp",
            "workspace_id": "w1"
          }
        ]
      }
    }
    """#

    static let agentList = #"""
    {
      "id": "cli:agent:list",
      "result": {
        "type": "agent_list",
        "agents": [
          {
            "agent": "pi",
            "agent_status": "idle",
            "cwd": "/recorded/project",
            "focused": false,
            "foreground_cwd": "/recorded/project",
            "pane_id": "w1:p1",
            "revision": 1,
            "tab_id": "w1:t1",
            "terminal_id": "term_0123456789ab",
            "terminal_title_stripped": "π - mudiapp",
            "workspace_id": "w1"
          }
        ]
      }
    }
    """#

    static let workspaceCreate = #"""
    {
      "id": "cli:workspace:create",
      "result": {
        "type": "workspace_created",
        "workspace": {
          "active_tab_id": "w1:t1",
          "label": "mudiapp",
          "workspace_id": "w1"
        },
        "tab": {
          "tab_id": "w1:t1",
          "workspace_id": "w1"
        },
        "root_pane": {
          "pane_id": "w1:p1",
          "tab_id": "w1:t1",
          "workspace_id": "w1"
        }
      }
    }
    """#
}
