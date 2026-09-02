import Foundation
import HerdrKit

/// Discovers Herdr with a dedicated SSH exec/session channel.
///
/// The authenticated interactive shell remains exclusively owned by
/// `TerminalViewContainer`. A command channel is opened by the underlying
/// Citadel connection and is collected to completion before decoding.
actor SSHHerdrDiscovery: HerdrDiscovering, HerdrWorkspaceCreating {
    private let session: SSHShellSession

    init(session: SSHShellSession) {
        self.session = session
    }

    func createWorkspace() async throws -> HerdrWorkspaceCreation {
        let data = try await session.execute(
            SSHLoginShellCommand.wrap("herdr workspace create --no-focus")
        )
        let response = try decode(
            SSHHerdrCLIResponse<SSHHerdrWorkspaceCreationPayload>.self,
            from: data
        )
        guard response.id == "cli:workspace:create",
              response.result.type == "workspace_created",
              !response.result.workspace.workspaceID.isEmpty,
              !response.result.tab.tabID.isEmpty,
              !response.result.rootPane.paneID.isEmpty
        else {
            throw SSHHerdrDiscoveryError.invalidEnvelope("workspace create")
        }
        return HerdrWorkspaceCreation(
            workspaceID: response.result.workspace.workspaceID,
            tabID: response.result.tab.tabID,
            rootPaneID: response.result.rootPane.paneID
        )
    }

    func snapshot(for _: Host) async throws -> HerdrSnapshot {
        let sessionList = try await decodeSessionList(
            from: try await session.execute(Self.command("session list --json"))
        )
        let runningSessions = sessionList.sessions.filter(\.running)
        guard !runningSessions.isEmpty else {
            return HerdrSnapshot(sessions: [])
        }

        var sessions: [HerdrSession] = []
        sessions.reserveCapacity(runningSessions.count)
        for sessionRecord in runningSessions {
            let workspaces = try await loadWorkspaces(for: sessionRecord.name)
            sessions.append(
                HerdrSession(
                    id: sessionRecord.name,
                    name: sessionRecord.name,
                    isDefault: sessionRecord.isDefault,
                    workspaces: workspaces
                )
            )
        }
        return HerdrSnapshot(sessions: sessions)
    }

    private func loadWorkspaces(for sessionName: String) async throws -> [Workspace] {
        let workspaceResponse = try await decode(
            SSHHerdrCLIResponse<SSHHerdrWorkspacePayload>.self,
            from: try await session.execute(
                Self.command("workspace list", sessionName: sessionName)
            )
        )
        guard workspaceResponse.id == "cli:workspace:list",
              workspaceResponse.result.type == "workspace_list"
        else {
            throw SSHHerdrDiscoveryError.invalidEnvelope("workspace list")
        }

        let paneResponse = try await decode(
            SSHHerdrCLIResponse<SSHHerdrPanePayload>.self,
            from: try await session.execute(
                Self.command("pane list", sessionName: sessionName)
            )
        )
        guard paneResponse.id == "cli:pane:list",
              paneResponse.result.type == "pane_list"
        else {
            throw SSHHerdrDiscoveryError.invalidEnvelope("pane list")
        }

        let agentResponse = try await decode(
            SSHHerdrCLIResponse<SSHHerdrAgentPayload>.self,
            from: try await session.execute(
                Self.command("agent list", sessionName: sessionName)
            )
        )
        guard agentResponse.id == "cli:agent:list",
              agentResponse.result.type == "agent_list"
        else {
            throw SSHHerdrDiscoveryError.invalidEnvelope("agent list")
        }

        return workspaceResponse.result.workspaces.map { workspace in
            makeWorkspace(
                from: workspace,
                panes: paneResponse.result.panes,
                agents: agentResponse.result.agents
            )
        }
    }

    private func makeWorkspace(
        from record: SSHHerdrWorkspaceRecord,
        panes: [SSHHerdrPaneRecord],
        agents: [SSHHerdrAgentRecord]
    ) -> Workspace {
        let workspacePanes = panes.filter { $0.workspaceID == record.workspaceID }
        var tabIDs = [record.activeTabID]
        for pane in workspacePanes where !tabIDs.contains(pane.tabID) {
            tabIDs.append(pane.tabID)
        }

        let tabs = tabIDs.map { tabID in
            Tab(
                id: tabID,
                name: tabID,
                panes: workspacePanes
                    .filter { $0.tabID == tabID }
                    .map { pane in makePane(from: pane, agents: agents) }
            )
        }
        return Workspace(
            id: record.workspaceID,
            name: record.label,
            tabs: tabs,
            worktree: record.worktree
        )
    }

    private func makePane(
        from record: SSHHerdrPaneRecord,
        agents: [SSHHerdrAgentRecord]
    ) -> Pane {
        let agent = agents.first { $0.paneID == record.paneID }
        let agentName = agent?.name ?? record.agent
        let paneAgent = agentName.map {
            Agent(
                name: $0,
                state: agentState(agent?.agentStatus ?? record.agentStatus)
            )
        }
        return Pane(id: record.paneID, title: record.title ?? record.paneID, agent: paneAgent)
    }

    private func agentState(_ value: String?) -> AgentState {
        switch value?.lowercased() {
        case "working": .working
        case "idle": .idle
        case "done": .done
        case "blocked", "waiting", "waiting_for_input", "waiting-for-input":
            .waitingForInput
        default: .unknown
        }
    }

    private func decodeSessionList(from data: [UInt8]) throws -> SSHHerdrSessionListResponse {
        let trimmed = try Self.trimmedResponse(from: data)
        guard !trimmed.isEmpty else {
            return SSHHerdrSessionListResponse(sessions: [])
        }
        do {
            return try JSONDecoder().decode(
                SSHHerdrSessionListResponse.self,
                from: Data(trimmed.utf8)
            )
        } catch {
            throw SSHHerdrDiscoveryError.invalidJSON
        }
    }

    private func decode<Value: Decodable>(
        _: Value.Type,
        from data: [UInt8]
    ) throws -> Value {
        let trimmed = try Self.trimmedResponse(from: data)
        guard !trimmed.isEmpty else {
            throw SSHHerdrDiscoveryError.invalidResponse
        }
        do {
            return try JSONDecoder().decode(Value.self, from: Data(trimmed.utf8))
        } catch {
            throw SSHHerdrDiscoveryError.invalidJSON
        }
    }

    private static func trimmedResponse(from data: [UInt8]) throws -> String {
        guard let response = String(data: Data(data), encoding: .utf8) else {
            throw SSHHerdrDiscoveryError.invalidResponse
        }
        return response.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func command(_ arguments: String, sessionName: String? = nil) -> String {
        var invocation = "herdr"
        if let sessionName {
            invocation += " --session \(SSHLoginShellCommand.shellQuote(sessionName))"
        }
        invocation += " \(arguments)"

        let command: String
        let fallbackExitCode: Int
        if sessionName == nil {
            command = "if command -v herdr >/dev/null 2>&1; then \(invocation); else exit 0; fi"
            fallbackExitCode = 0
        } else {
            command = invocation
            fallbackExitCode = 127
        }
        return SSHLoginShellCommand.wrap(
            command,
            fallbackExitCode: fallbackExitCode
        )
    }
}

enum SSHHerdrDiscoveryError: Error, LocalizedError, Sendable {
    case invalidResponse
    case invalidJSON
    case invalidEnvelope(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse, .invalidJSON, .invalidEnvelope:
            "Herdr discovery returned an invalid response."
        }
    }
}

private struct SSHHerdrSessionListResponse: Decodable {
    let sessions: [SSHHerdrSessionRecord]
}

private struct SSHHerdrSessionRecord: Decodable {
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

private struct SSHHerdrCLIResponse<Result: Decodable>: Decodable {
    let id: String
    let result: Result
}

private struct SSHHerdrWorkspacePayload: Decodable {
    let type: String
    let workspaces: [SSHHerdrWorkspaceRecord]
}

private struct SSHHerdrWorkspaceRecord: Decodable {
    let activeTabID: String
    let label: String
    let workspaceID: String
    let worktree: WorktreeMetadata?

    enum CodingKeys: String, CodingKey {
        case activeTabID = "active_tab_id"
        case label
        case workspaceID = "workspace_id"
        case worktree
    }
}

private struct SSHHerdrPanePayload: Decodable {
    let type: String
    let panes: [SSHHerdrPaneRecord]
}

private struct SSHHerdrAgentPayload: Decodable {
    let type: String
    let agents: [SSHHerdrAgentRecord]
}

private struct SSHHerdrPaneRecord: Decodable {
    let paneID: String
    let tabID: String
    let workspaceID: String
    let agent: String?
    let agentStatus: String
    let title: String?

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case tabID = "tab_id"
        case workspaceID = "workspace_id"
        case agent
        case agentStatus = "agent_status"
        case title = "terminal_title_stripped"
    }
}

private struct SSHHerdrAgentRecord: Decodable {
    let paneID: String
    let name: String
    let agentStatus: String

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case name = "agent"
        case agentStatus = "agent_status"
    }
}

private struct SSHHerdrWorkspaceCreationPayload: Decodable {
    let type: String
    let workspace: SSHHerdrCreatedWorkspace
    let tab: SSHHerdrCreatedTab
    let rootPane: SSHHerdrCreatedPane

    enum CodingKeys: String, CodingKey {
        case rootPane = "root_pane"
        case tab
        case type
        case workspace
    }
}

private struct SSHHerdrCreatedWorkspace: Decodable {
    let workspaceID: String

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
    }
}

private struct SSHHerdrCreatedTab: Decodable {
    let tabID: String

    enum CodingKeys: String, CodingKey {
        case tabID = "tab_id"
    }
}

private struct SSHHerdrCreatedPane: Decodable {
    let paneID: String

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
    }
}
