import Foundation
import HerdrKit

/// Identity comes from official discovery, never terminal titles or pixels.
/// Pane IDs can repeat on another Host or named Herdr session.
struct TerminalAgentActionsContext: Equatable {
    let hostID: Host.ID
    let sessionID: HerdrSession.ID?
    let paneID: Pane.ID?
    let agentName: String?

    init(hostID: Host.ID, sessionID: HerdrSession.ID? = nil, pane: Pane? = nil) {
        self.hostID = hostID
        self.sessionID = sessionID
        paneID = pane?.id
        agentName = pane?.agent?.name
    }

    var normalizedAgentName: String? {
        let name = agentName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return name?.isEmpty == false ? name : nil
    }

    var recommendedPreset: TerminalAgentPreset {
        switch normalizedAgentName {
        case "pi": return .pi
        case "claude code": return .claudeCode
        case "codex": return .claudeCode
        default: return .generic
        }
    }

    func hasSameScopeAndType(as other: Self) -> Bool {
        hostID == other.hostID && sessionID == other.sessionID
            && paneID == other.paneID && normalizedAgentName == other.normalizedAgentName
    }
}

enum TerminalAgentPreset: Int, CaseIterable {
    case generic, pi, claudeCode

    var title: String {
        switch self {
        case .generic: return "通用"
        case .pi: return "Pi"
        case .claudeCode: return "Claude Code"
        }
    }

    /// Pi 1.1.0 defaults, verified against keybindings.md and slash-commands.md.
    /// Custom remote bindings are deliberately not guessed or overwritten.
    var actions: [TerminalAgentAction] {
        builtInActions + configuredModels.map { .command("configured-model-" + $0, "模型：" + $0, "/model " + $0) }
    }

    var configuredModels: [String] {
        guard self != .generic else { return [] }
        return UserDefaults.standard.stringArray(forKey: "agent-models-" + String(rawValue)) ?? []
    }

    func saveModels(_ text: String) {
        let models = text.components(separatedBy: .newlines).map { (line: String) -> String in
            let value = line.trimmingCharacters(in: .whitespaces)
            return value.hasPrefix("/model ") ? String(value.dropFirst(7)).trimmingCharacters(in: .whitespaces) : value
        }.filter { (value: String) in !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 47, 58, 95].contains($0) } }
        var unique: [String] = []
        for model in models where !unique.contains(model) { unique.append(model) }
        UserDefaults.standard.set(unique, forKey: "agent-models-" + String(rawValue))
    }

    private var builtInActions: [TerminalAgentAction] {
        switch self {
        case .generic:
            [
                .key("escape", "Esc", "Esc", [0x1b]),
                .key("tab", "Tab", "Tab", [0x09]),
                .key("shift-tab", "Shift+Tab", "Shift+Tab", [0x1b, 0x5b, 0x5a]),
                .key("control-c", "Ctrl+C", "Ctrl+C", [0x03]),
                .key("control-d", "Ctrl+D", "Ctrl+D", [0x04]),
                .key("control-l", "Ctrl+L", "Ctrl+L", [0x0c]),
                .key("control-o", "Ctrl+O", "Ctrl+O", [0x0f]),
                .key("control-t", "Ctrl+T", "Ctrl+T", [0x14]),
            ]
        case .pi:
            [
                .command("reload", "重新加载配置", "/reload"),
                .command("compact", "压缩上下文", "/compact"),
                .command("resume", "切换会话", "/resume"),
                .command("tree", "会话树", "/tree"),
            ]
        case .claudeCode:
            [
                .command("model", "选择模型", "/model"),
                .command("context", "查看上下文", "/context"),
                .command("compact", "压缩上下文", "/compact"),
                .command("resume", "恢复会话", "/resume"),
                .command("usage", "查看用量", "/usage"),
                .command("rewind", "回滚检查点", "/rewind"),
                .command("clear", "清空并新开会话", "/clear"),
                .command("tasks", "后台任务", "/tasks"),
            ]
        }
    }
}

struct TerminalAgentAction: Identifiable, Equatable {
    enum Input: Equatable {
        case key([UInt8])
        case command(String)
    }

    let id: String
    let title: String
    let keyLabel: String
    let input: Input

    static func key(_ id: String, _ title: String, _ label: String, _ bytes: [UInt8]) -> Self {
        Self(id: id, title: title, keyLabel: label, input: .key(bytes))
    }

    static func command(_ id: String, _ title: String, _ command: String) -> Self {
        Self(id: id, title: title, keyLabel: command, input: .command(command))
    }
}

/// The pending command is a single-use confirmation owned by this context.
/// A pane/Host/session/type change discards it and the manual preset override;
/// refreshing just an agent's state or title preserves the user's selection.
struct TerminalAgentActionsState {
    private(set) var context: TerminalAgentActionsContext?
    private(set) var preset: TerminalAgentPreset = .generic
    private(set) var pendingCommand: String?

    mutating func updateContext(_ context: TerminalAgentActionsContext?) {
        let sameContext: Bool
        switch (self.context, context) {
        case (nil, nil): sameContext = true
        case let (old?, new?): sameContext = old.hasSameScopeAndType(as: new)
        default: sameContext = false
        }
        self.context = context
        guard !sameContext else { return }
        preset = context?.recommendedPreset ?? .generic
        pendingCommand = nil
    }

    mutating func selectPreset(_ preset: TerminalAgentPreset) {
        self.preset = preset
        pendingCommand = nil
    }

    mutating func selectAction(_ id: String) -> [UInt8]? {
        guard let action = preset.actions.first(where: { $0.id == id }) else { return nil }
        pendingCommand = nil
        switch action.input {
        case let .key(bytes): return bytes
        case let .command(text):
            pendingCommand = text
            return nil
        }
    }

    mutating func confirmCommand() -> [UInt8]? {
        guard let pendingCommand else { return nil }
        self.pendingCommand = nil
        // Raw PTY input, not an exec command or an implicit editor-clear.
        return Array((pendingCommand + "\r").utf8)
    }

    mutating func cancelCommand() {
        pendingCommand = nil
    }
}
