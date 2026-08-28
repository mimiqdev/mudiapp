import Foundation

public struct HerdrSnapshot: Codable, Equatable, Sendable {
    public var sessions: [HerdrSession]

    public init(sessions: [HerdrSession]) {
        self.sessions = sessions
    }
}

public struct HerdrSession: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var isDefault: Bool
    public var workspaces: [Workspace]

    public init(
        id: String,
        name: String,
        isDefault: Bool = false,
        workspaces: [Workspace]
    ) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.workspaces = workspaces
    }
}

public struct Workspace: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var tabs: [Tab]

    public init(id: String, name: String, tabs: [Tab]) {
        self.id = id
        self.name = name
        self.tabs = tabs
    }
}

public struct Tab: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var panes: [Pane]

    public init(id: String, name: String, panes: [Pane]) {
        self.id = id
        self.name = name
        self.panes = panes
    }
}

public struct Pane: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var title: String
    public var agent: Agent?

    public init(id: String, title: String, agent: Agent? = nil) {
        self.id = id
        self.title = title
        self.agent = agent
    }
}

public struct Agent: Codable, Equatable, Sendable {
    public var name: String
    public var state: AgentState

    public init(name: String, state: AgentState) {
        self.name = name
        self.state = state
    }
}

public enum AgentState: String, Codable, CaseIterable, Sendable {
    case working
    case waitingForInput
    case idle
    case done
    case unknown
}
