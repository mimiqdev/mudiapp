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

public struct WorktreeMetadata: Codable, Equatable, Sendable {
    public let checkoutPath: String?
    public let isLinkedWorktree: Bool
    public let repoKey: String?
    public let repoName: String?
    public let repoRoot: String?

    public init(
        checkoutPath: String? = nil,
        isLinkedWorktree: Bool = false,
        repoKey: String? = nil,
        repoName: String? = nil,
        repoRoot: String? = nil
    ) {
        self.checkoutPath = checkoutPath
        self.isLinkedWorktree = isLinkedWorktree
        self.repoKey = repoKey
        self.repoName = repoName
        self.repoRoot = repoRoot
    }

    private enum CodingKeys: String, CodingKey {
        case checkoutPath = "checkout_path"
        case isLinkedWorktree = "is_linked_worktree"
        case repoKey = "repo_key"
        case repoName = "repo_name"
        case repoRoot = "repo_root"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        checkoutPath = try container.decodeIfPresent(
            String.self,
            forKey: .checkoutPath
        )
        isLinkedWorktree = try container.decodeIfPresent(
            Bool.self,
            forKey: .isLinkedWorktree
        ) ?? false
        repoKey = try container.decodeIfPresent(String.self, forKey: .repoKey)
        repoName = try container.decodeIfPresent(String.self, forKey: .repoName)
        repoRoot = try container.decodeIfPresent(String.self, forKey: .repoRoot)
    }
}

public struct Workspace: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var tabs: [Tab]
    public var worktree: WorktreeMetadata?

    public init(
        id: String,
        name: String,
        tabs: [Tab],
        worktree: WorktreeMetadata? = nil
    ) {
        self.id = id
        self.name = name
        self.tabs = tabs
        self.worktree = worktree
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
