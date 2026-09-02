import HerdrKit

/// The flattened, user-facing projection of one pane. The source snapshot
/// still retains its complete session/workspace/tab hierarchy; this value only
/// carries the context needed to render and select a pane.
struct PanePickerPresentationRow: Identifiable, Equatable, Sendable {
    let id: Pane.ID
    let pane: Pane
    let sessionID: HerdrSession.ID
    let workspaceContext: String?

    var paneID: Pane.ID { id }

    var name: String {
        pane.agent?.name ?? pane.title
    }

    var terminalTitle: String {
        pane.title
    }

    var visibleText: [String] {
        var text = [name, terminalTitle]
        if let workspaceContext {
            text.append(workspaceContext)
        }
        return text
    }
}

/// A repository/worktree node in the picker. Tabs are intentionally absent
/// from this projection: their panes are listed directly under the workspace
/// node while the original tab IDs remain in ``HerdrSnapshot``.
struct PanePickerWorkspacePresentation: Identifiable, Equatable, Sendable {
    let id: Workspace.ID
    let title: String
    let isLinkedWorktree: Bool
    let rows: [PanePickerPresentationRow]
    let children: [PanePickerWorkspacePresentation]

    var allRows: [PanePickerPresentationRow] {
        rows + children.flatMap(\.allRows)
    }

    var visibleText: [String] {
        [title] + rows.flatMap(\.visibleText) + children.flatMap(\.visibleText)
    }
}

/// A session remains the outer grouping when a Herdr server exposes more than
/// one running session. A single session uses the human ``Herdr panes`` label
/// so the UI does not add an unnecessary session hierarchy level.
struct PanePickerSessionPresentation: Identifiable, Equatable, Sendable {
    let id: HerdrSession.ID
    let title: String
    let isDefault: Bool
    let roots: [PanePickerWorkspacePresentation]

    var rows: [PanePickerPresentationRow] {
        roots.flatMap(\.allRows)
    }

    var visibleText: [String] {
        [title] + roots.flatMap(\.visibleText)
    }
}

/// Builds the pane-picker projection from authoritative snapshot metadata.
/// Worktree relationships are grouped only by ``repo_key`` and the linked
/// flag supplied by Herdr; no checkout-path or workspace-name heuristics are
/// used.
func panePickerPresentationSections(
    in snapshot: HerdrSnapshot
) -> [PanePickerSessionPresentation] {
    snapshot.sessions.map { session in
        let unresolvedRoots = makeWorkspaceTree(session.workspaces)
        let workspaceNamesByPaneName = workspaceNamesByPaneName(
            in: unresolvedRoots
        )
        let duplicatePaneNames = Set(
            workspaceNamesByPaneName.compactMap { name, workspaceIDs in
                workspaceIDs.count > 1 ? name : nil
            }
        )
        let roots = unresolvedRoots.map { node in
            makePresentationNode(
                node,
                sessionID: session.id,
                duplicatePaneNames: duplicatePaneNames
            )
        }
        let title = snapshot.sessions.count == 1
            ? "Herdr panes"
            : humanSessionTitle(session.name)
        return PanePickerSessionPresentation(
            id: session.id,
            title: title,
            isDefault: session.isDefault,
            roots: roots
        )
    }
}

private struct UnresolvedWorkspaceNode {
    let workspace: Workspace
    var children: [UnresolvedWorkspaceNode]
}

private func makeWorkspaceTree(
    _ workspaces: [Workspace]
) -> [UnresolvedWorkspaceNode] {
    var roots: [UnresolvedWorkspaceNode] = []
    var rootIndexByRepoKey: [String: Int] = [:]
    var pendingLinkedWorktrees: [String: [UnresolvedWorkspaceNode]] = [:]
    var pendingRepoKeyOrder: [String] = []

    for workspace in workspaces {
        guard let repoKey = nonEmpty(workspace.worktree?.repoKey) else {
            roots.append(UnresolvedWorkspaceNode(workspace: workspace, children: []))
            continue
        }

        let node = UnresolvedWorkspaceNode(workspace: workspace, children: [])
        if workspace.worktree?.isLinkedWorktree == true {
            if let rootIndex = rootIndexByRepoKey[repoKey] {
                roots[rootIndex].children.append(node)
            } else {
                if pendingLinkedWorktrees[repoKey] == nil {
                    pendingRepoKeyOrder.append(repoKey)
                }
                pendingLinkedWorktrees[repoKey, default: []].append(node)
            }
            continue
        }

        if rootIndexByRepoKey[repoKey] != nil {
            // Herdr normally reports one primary checkout per repo_key. If a
            // malformed/legacy response reports another, keep its panes
            // visible as an additional root instead of merging workspaces.
            roots.append(node)
        } else {
            let rootIndex = roots.count
            var root = node
            root.children = pendingLinkedWorktrees.removeValue(forKey: repoKey) ?? []
            pendingRepoKeyOrder.removeAll { $0 == repoKey }
            roots.append(root)
            rootIndexByRepoKey[repoKey] = rootIndex
        }
    }

    // A linked workspace without a currently reported primary checkout is
    // still useful. Keep it visible as a standalone root rather than infer a
    // parent from a path or name.
    for repoKey in pendingRepoKeyOrder {
        roots.append(contentsOf: pendingLinkedWorktrees[repoKey] ?? [])
    }
    return roots
}

private func workspaceNamesByPaneName(
    in roots: [UnresolvedWorkspaceNode]
) -> [String: Set<Workspace.ID>] {
    var result: [String: Set<Workspace.ID>] = [:]
    for node in roots {
        for pane in panes(in: node.workspace) {
            result[displayName(for: pane), default: []].insert(node.workspace.id)
        }
        let childNames = workspaceNamesByPaneName(in: node.children)
        for (name, workspaceIDs) in childNames {
            result[name, default: []].formUnion(workspaceIDs)
        }
    }
    return result
}

private func makePresentationNode(
    _ node: UnresolvedWorkspaceNode,
    sessionID: HerdrSession.ID,
    duplicatePaneNames: Set<String>
) -> PanePickerWorkspacePresentation {
    let workspaceTitle = humanWorkspaceTitle(node.workspace)
    let context = duplicatePaneNames
    let rows = panes(in: node.workspace).map { pane in
        PanePickerPresentationRow(
            id: pane.id,
            pane: pane,
            sessionID: sessionID,
            workspaceContext: context.contains(displayName(for: pane))
                ? workspaceTitle
                : nil
        )
    }
    return PanePickerWorkspacePresentation(
        id: node.workspace.id,
        title: workspaceTitle,
        isLinkedWorktree: node.workspace.worktree?.isLinkedWorktree == true,
        rows: rows,
        children: node.children.map {
            makePresentationNode(
                $0,
                sessionID: sessionID,
                duplicatePaneNames: duplicatePaneNames
            )
        }
    )
}

private func panes(in workspace: Workspace) -> [Pane] {
    workspace.tabs.flatMap { tab in tab.panes }
}

private func displayName(for pane: Pane) -> String {
    pane.agent?.name ?? pane.title
}

private func humanSessionTitle(_ value: String) -> String {
    nonEmpty(value) ?? "Herdr session"
}

private func humanWorkspaceTitle(_ workspace: Workspace) -> String {
    nonEmpty(workspace.name)
        ?? nonEmpty(workspace.worktree?.repoName)
        ?? "Herdr workspace"
}

private func nonEmpty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
