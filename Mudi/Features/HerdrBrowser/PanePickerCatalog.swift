import Foundation
import HerdrKit

enum PanePickerFilter: String, CaseIterable {
    case all, waiting, working, done
    var title: String {
        switch self {
        case .all: "全部"
        case .waiting: "需要输入"
        case .working: "正在工作"
        case .done: "已完成"
        }
    }
    func includes(_ pane: Pane) -> Bool {
        switch self {
        case .all: true
        case .waiting: pane.agent?.state == .waitingForInput
        case .working: pane.agent?.state == .working
        case .done: pane.agent?.state == .done
        }
    }
}

/// A searchable projection of existing discovery data; no new wire fields.
struct PanePickerCatalog {
    struct Entry: Identifiable {
        var id: Pane.ID { pane.id }
        let pane: Pane
        let sessionID: HerdrSession.ID
        let projectID: String
        let projectTitle: String
        let context: String
        let searchText: String
    }
    let rows: [Entry]
    init(host: Host, snapshot: HerdrSnapshot) {
        rows = snapshot.sessions.flatMap { session in
            session.workspaces.flatMap { workspace in
                workspace.tabs.flatMap { tab in
                    tab.panes.map { pane in
                        let repo = workspace.worktree?.repoName ?? workspace.name
                        let context = [host.displayName, repo, workspace.name, tab.name]
                            .filter { !$0.isEmpty }.reduce(into: [String]()) { values, value in
                                if values.last != value { values.append(value) }
                            }.joined(separator: " / ")
                        let search = [pane.agent?.name, pane.title, host.displayName, host.hostname,
                                      repo, workspace.name, workspace.worktree?.checkoutPath,
                                      workspace.worktree?.repoRoot, tab.name, session.name]
                            .compactMap { $0 }.joined(separator: " ")
                        return Entry(
                            pane: pane, sessionID: session.id,
                            projectID: session.id + ":" + (workspace.worktree?.repoKey ?? workspace.id),
                            projectTitle: "\(host.displayName) / \(repo)" + (snapshot.sessions.count > 1 ? " · \(session.name)" : ""),
                            context: context, searchText: search
                        )
                    }
                }
            }
        }
    }
    func matching(query: String, filter: PanePickerFilter) -> [Entry] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return rows.filter { entry in
            filter.includes(entry.pane) && terms.allSatisfy {
                entry.searchText.localizedStandardContains($0)
            }
        }
    }
}

@MainActor
final class PanePickerHistory: ObservableObject {
    private struct Key: Hashable, Codable {
        let hostID: UUID
        let paneID: String
    }
    private struct Saved: Codable {
        var favorites: Set<Key> = []
        var recent: [Key] = []
    }
    @Published private var saved: Saved
    private let defaults: UserDefaults
    private let storageKey = "dev.mudi.mobile.pane-history"
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        saved = defaults.data(forKey: storageKey)
            .flatMap { try? JSONDecoder().decode(Saved.self, from: $0) } ?? Saved()
    }
    func isFavorite(hostID: UUID, paneID: String) -> Bool {
        saved.favorites.contains(Key(hostID: hostID, paneID: paneID))
    }
    func toggleFavorite(hostID: UUID, paneID: String) {
        let key = Key(hostID: hostID, paneID: paneID)
        if saved.favorites.contains(key) { saved.favorites.remove(key) }
        else { saved.favorites.insert(key) }
        persist()
    }
    func recordSelection(hostID: UUID, paneID: String) {
        let key = Key(hostID: hostID, paneID: paneID)
        saved.recent.removeAll { $0 == key }
        saved.recent.insert(key, at: 0)
        saved.recent = Array(saved.recent.prefix(40))
        persist()
    }
    func recentPaneIDs(hostID: UUID) -> [String] {
        saved.recent.filter { $0.hostID == hostID }.map(\.paneID)
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: storageKey) }
    }
}
