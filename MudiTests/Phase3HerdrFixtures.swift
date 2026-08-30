import Foundation
import HerdrKit

/// A decoded transcript of the real Herdr CLI commands used by phase 3.
///
/// The app's current discovery protocol still accepts `HerdrSnapshot`, so the
/// test discovery below uses this fixture as a bridge at its boundary. The
/// fixture itself is built from the separate `session list`, `workspace list`,
/// `pane list`, and `agent list` payloads rather than from a snapshot-shaped
/// JSON document.
struct Phase3HerdrFixture: Sendable {
    let sessions: [HerdrSession]

    init(
        sessionListPayload: String,
        detailsBySession: [String: Phase3HerdrSessionDetails]
    ) throws {
        let sessionList = try Self.decode(
            Phase3SessionListResponse.self,
            from: sessionListPayload
        )

        sessions = sessionList.sessions
            .filter(\.running)
            .map { session in
                HerdrSession(
                    id: session.name,
                    name: session.name,
                    isDefault: session.isDefault,
                    workspaces: detailsBySession[session.name]?.workspaces ?? []
                )
            }
    }

    private static func decode<Value: Decodable>(
        _: Value.Type,
        from payload: String
    ) throws -> Value {
        try JSONDecoder().decode(Value.self, from: Data(payload.utf8))
    }
}

/// The three command envelopes Herdr returns after a session is selected.
struct Phase3HerdrSessionDetails: Sendable {
    let workspaces: [Workspace]

    init(
        workspaceListPayload: String,
        paneListPayload: String,
        agentListPayload: String
    ) throws {
        let workspaceList = try Self.decode(
            Phase3WorkspaceListResponse.self,
            from: workspaceListPayload
        )
        let paneList = try Self.decode(
            Phase3PaneListResponse.self,
            from: paneListPayload
        )
        let agentList = try Self.decode(
            Phase3AgentListResponse.self,
            from: agentListPayload
        )

        guard workspaceList.id == "cli:workspace:list",
              workspaceList.result.type == "workspace_list"
        else {
            throw Phase3HerdrFixtureError.invalidEnvelope("workspace list")
        }
        guard paneList.id == "cli:pane:list",
              paneList.result.type == "pane_list"
        else {
            throw Phase3HerdrFixtureError.invalidEnvelope("pane list")
        }
        guard agentList.id == "cli:agent:list",
              agentList.result.type == "agent_list"
        else {
            throw Phase3HerdrFixtureError.invalidEnvelope("agent list")
        }

        let agentsByPaneID = Dictionary(
            uniqueKeysWithValues: agentList.result.agents.map { ($0.paneID, $0) }
        )
        workspaces = workspaceList.result.workspaces.map { workspace in
            let panes = paneList.result.panes.filter {
                $0.workspaceID == workspace.workspaceID
            }
            let tabIDs = Self.orderedUnique(
                [workspace.activeTabID] + panes.map(\.tabID)
            )
            let tabs = tabIDs.map { tabID in
                Tab(
                    id: tabID,
                    name: tabID,
                    panes: panes
                        .filter { $0.tabID == tabID }
                        .map { pane in
                            let agent = agentsByPaneID[pane.paneID]
                            let agentName = agent?.name ?? pane.agent
                            return Pane(
                                id: pane.paneID,
                                title: pane.title,
                                agent: agentName.map {
                                    Agent(
                                        name: $0,
                                        state: Self.agentState(
                                            agent?.agentStatus ?? pane.agentStatus
                                        )
                                    )
                                }
                            )
                        }
                )
            }
            return Workspace(
                id: workspace.workspaceID,
                name: workspace.label,
                tabs: tabs
            )
        }
    }

    private static func decode<Value: Decodable>(
        _: Value.Type,
        from payload: String
    ) throws -> Value {
        try JSONDecoder().decode(Value.self, from: Data(payload.utf8))
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var result: [String] = []
        for value in values where !result.contains(value) {
            result.append(value)
        }
        return result
    }

    private static func agentState(_ value: String?) -> AgentState {
        switch value?.lowercased() {
        case "working": .working
        case "idle": .idle
        case "done": .done
        case "blocked", "waiting", "waiting_for_input", "waiting-for-input":
            .waitingForInput
        default: .unknown
        }
    }
}

enum Phase3HerdrFixtureError: Error, Equatable, LocalizedError, Sendable {
    case invalidEnvelope(String)

    var errorDescription: String? {
        switch self {
        case let .invalidEnvelope(command):
            "The recorded Herdr \(command) response has an unexpected envelope."
        }
    }
}

private struct Phase3SessionListResponse: Decodable, Sendable {
    let sessions: [Session]

    struct Session: Decodable, Sendable {
        let isDefault: Bool
        let name: String
        let running: Bool
        let sessionDirectory: String
        let socketPath: String

        enum CodingKeys: String, CodingKey {
            case isDefault = "default"
            case name
            case running
            case sessionDirectory = "session_dir"
            case socketPath = "socket_path"
        }
    }
}

private struct Phase3WorkspaceListResponse: Decodable, Sendable {
    let id: String
    let result: Payload

    struct Payload: Decodable, Sendable {
        let type: String
        let workspaces: [WorkspaceRecord]
    }

    struct WorkspaceRecord: Decodable, Sendable {
        let activeTabID: String
        let label: String
        let workspaceID: String

        enum CodingKeys: String, CodingKey {
            case activeTabID = "active_tab_id"
            case label
            case workspaceID = "workspace_id"
        }
    }
}

private struct Phase3PaneListResponse: Decodable, Sendable {
    let id: String
    let result: Payload

    struct Payload: Decodable, Sendable {
        let type: String
        let panes: [PaneRecord]
    }

    struct PaneRecord: Decodable, Sendable {
        let paneID: String
        let tabID: String
        let workspaceID: String
        let agent: String?
        let agentStatus: String
        let title: String

        enum CodingKeys: String, CodingKey {
            case paneID = "pane_id"
            case tabID = "tab_id"
            case workspaceID = "workspace_id"
            case agent
            case agentStatus = "agent_status"
            case title = "terminal_title_stripped"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            paneID = try container.decode(String.self, forKey: .paneID)
            tabID = try container.decode(String.self, forKey: .tabID)
            workspaceID = try container.decode(String.self, forKey: .workspaceID)
            agent = try container.decodeIfPresent(String.self, forKey: .agent)
            agentStatus = try container.decode(String.self, forKey: .agentStatus)
            title = try container.decodeIfPresent(String.self, forKey: .title) ?? paneID
        }
    }
}

private struct Phase3AgentListResponse: Decodable, Sendable {
    let id: String
    let result: Payload

    struct Payload: Decodable, Sendable {
        let type: String
        let agents: [AgentRecord]
    }

    struct AgentRecord: Decodable, Sendable {
        let paneID: String
        let name: String
        let agentStatus: String

        enum CodingKeys: String, CodingKey {
            case paneID = "pane_id"
            case name = "agent"
            case agentStatus = "agent_status"
        }
    }
}

/// Payloads recorded from Herdr 0.8.2. The command-specific envelope and
/// field names are kept as emitted by the CLI; volatile metadata and paths are
/// trimmed or anonymized where it is not relevant to these workflow tests.
enum Phase3HerdrFixtures {
    static func empty() throws -> Phase3HerdrFixture {
        try Phase3HerdrFixture(
            sessionListPayload: stoppedDefaultSessionList,
            detailsBySession: [:]
        )
    }

    static func single() throws -> Phase3HerdrFixture {
        let details = try defaultSessionDetails()
        return try Phase3HerdrFixture(
            sessionListPayload: singleSessionList,
            detailsBySession: ["default": details]
        )
    }

    static func multiple() throws -> Phase3HerdrFixture {
        let defaultDetails = try defaultSessionDetails()
        let namedDetails = try namedSessionDetails()
        return try Phase3HerdrFixture(
            sessionListPayload: multipleSessionList,
            detailsBySession: [
                "default": defaultDetails,
                "phase3-cli-fixture": namedDetails,
            ]
        )
    }

    private static func defaultSessionDetails() throws -> Phase3HerdrSessionDetails {
        try Phase3HerdrSessionDetails(
            workspaceListPayload: defaultWorkspaceList,
            paneListPayload: defaultPaneList,
            agentListPayload: defaultAgentList
        )
    }

    private static func namedSessionDetails() throws -> Phase3HerdrSessionDetails {
        try Phase3HerdrSessionDetails(
            workspaceListPayload: namedWorkspaceList,
            paneListPayload: namedPaneList,
            agentListPayload: namedAgentList
        )
    }

    private static let stoppedDefaultSessionList = #"""
    {
      "sessions": [
        {
          "default": true,
          "name": "default",
          "running": false,
          "session_dir": "/recorded/herdr",
          "socket_path": "/recorded/herdr/herdr.sock"
        }
      ]
    }
    """#

    private static let singleSessionList = #"""
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

    private static let multipleSessionList = #"""
    {
      "sessions": [
        {
          "default": true,
          "name": "default",
          "running": true,
          "session_dir": "/recorded/herdr",
          "socket_path": "/recorded/herdr/herdr.sock"
        },
        {
          "default": false,
          "name": "phase3-cli-fixture",
          "running": true,
          "session_dir": "/recorded/herdr/sessions/phase3-cli-fixture",
          "socket_path": "/recorded/herdr/sessions/phase3-cli-fixture/herdr.sock"
        }
      ]
    }
    """#

    private static let defaultWorkspaceList = #"""
    {
      "id": "cli:workspace:list",
      "result": {
        "type": "workspace_list",
        "workspaces": [
          {
            "active_tab_id": "w55:t1",
            "agent_status": "idle",
            "focused": true,
            "label": "mudiapp",
            "number": 1,
            "pane_count": 1,
            "tab_count": 1,
            "workspace_id": "w55"
          },
          {
            "active_tab_id": "w56:t1",
            "agent_status": "idle",
            "focused": false,
            "label": "qing",
            "number": 2,
            "pane_count": 1,
            "tab_count": 1,
            "workspace_id": "w56"
          },
          {
            "active_tab_id": "w58:t1",
            "agent_status": "unknown",
            "focused": false,
            "label": "mudiapp",
            "number": 3,
            "pane_count": 1,
            "tab_count": 1,
            "workspace_id": "w58"
          }
        ]
      }
    }
    """#

    private static let defaultPaneList = #"""
    {
      "id": "cli:pane:list",
      "result": {
        "panes": [
          {
            "agent": "pi",
            "agent_status": "idle",
            "cwd": "/recorded/mudiapp",
            "focused": true,
            "foreground_cwd": "/recorded/mudiapp",
            "pane_id": "w55:p1",
            "revision": 1,
            "tab_id": "w55:t1",
            "terminal_id": "term_65a1d4135cfa21",
            "terminal_title": "π - mudiapp",
            "terminal_title_stripped": "π - mudiapp",
            "workspace_id": "w55"
          },
          {
            "agent": "pi",
            "agent_status": "idle",
            "cwd": "/recorded/qing",
            "focused": false,
            "foreground_cwd": "/recorded/qing",
            "pane_id": "w56:p1",
            "revision": 1,
            "tab_id": "w56:t1",
            "terminal_id": "term_65a1d4431d3062",
            "terminal_title": "π - qing",
            "terminal_title_stripped": "π - qing",
            "workspace_id": "w56"
          },
          {
            "agent_status": "unknown",
            "cwd": "/recorded/mudiapp",
            "focused": false,
            "foreground_cwd": "/recorded/mudiapp",
            "pane_id": "w58:p1",
            "revision": 0,
            "tab_id": "w58:t1",
            "terminal_id": "term_65a1e872e43535",
            "workspace_id": "w58"
          }
        ],
        "type": "pane_list"
      }
    }
    """#

    private static let defaultAgentList = #"""
    {
      "id": "cli:agent:list",
      "result": {
        "agents": [
          {
            "agent": "pi",
            "agent_status": "idle",
            "pane_id": "w55:p1",
            "tab_id": "w55:t1",
            "terminal_id": "term_65a1d4135cfa21",
            "terminal_title": "π - mudiapp",
            "terminal_title_stripped": "π - mudiapp",
            "workspace_id": "w55"
          },
          {
            "agent": "pi",
            "agent_status": "idle",
            "pane_id": "w56:p1",
            "tab_id": "w56:t1",
            "terminal_id": "term_65a1d4431d3062",
            "terminal_title": "π - qing",
            "terminal_title_stripped": "π - qing",
            "workspace_id": "w56"
          }
        ],
        "type": "agent_list"
      }
    }
    """#

    private static let namedWorkspaceList = #"""
    {
      "id": "cli:workspace:list",
      "result": {
        "type": "workspace_list",
        "workspaces": [
          {
            "active_tab_id": "w1:t1",
            "agent_status": "unknown",
            "focused": true,
            "label": "mudiapp-herdr-cli-tests",
            "number": 1,
            "pane_count": 1,
            "tab_count": 1,
            "workspace_id": "w1"
          }
        ]
      }
    }
    """#

    private static let namedPaneList = #"""
    {
      "id": "cli:pane:list",
      "result": {
        "panes": [
          {
            "agent_status": "unknown",
            "cwd": "/recorded/mudiapp-herdr-cli-tests",
            "focused": true,
            "foreground_cwd": "/recorded/mudiapp-herdr-cli-tests",
            "pane_id": "w1:p1",
            "revision": 0,
            "scroll": {
              "max_offset_from_bottom": 29,
              "offset_from_bottom": 0,
              "viewport_rows": 23
            },
            "tab_id": "w1:t1",
            "terminal_id": "term_65a4212da43c91",
            "workspace_id": "w1"
          }
        ],
        "type": "pane_list"
      }
    }
    """#

    private static let namedAgentList = #"""
    {
      "id": "cli:agent:list",
      "result": {
        "agents": [],
        "type": "agent_list"
      }
    }
    """#
}
