import HerdrKit
import SwiftUI

struct PanePickerPresentationPolicy: Equatable {
    enum CompactDetent: String, CaseIterable, Equatable {
        case medium
        case large

        var presentationDetent: PresentationDetent {
            switch self {
            case .medium:
                .medium
            case .large:
                .large
            }
        }
    }

    let compactDetents: [CompactDetent]
    let showsDragIndicator: Bool
    /// The system sheet/popover handles outside taps and swipe-down as a
    /// user dismissal natively. Disabling that and re-adding it with custom
    /// gesture bridges breaks detent dragging, so dismissal stays native and
    /// flows through the presentation Binding into `dismissPanePicker()`.
    let usesSystemInteractiveDismissal: Bool

    static let compactSheet = PanePickerPresentationPolicy(
        compactDetents: [.medium, .large],
        showsDragIndicator: true,
        usesSystemInteractiveDismissal: true
    )

    /// iPad sheet width cap: the sheet is centered with a content-capped
    /// width (not full width); height is driven by the medium/large
    /// detents.
    static func popoverContentWidth(for containerWidth: CGFloat) -> CGFloat {
        min(420, max(320, containerWidth * 0.36))
    }

    var detents: Set<PresentationDetent> {
        Set(compactDetents.map(\.presentationDetent))
    }

    var dragIndicator: Visibility {
        showsDragIndicator ? .visible : .automatic
    }
}

/// The one picker surface used after Host connection and from a terminal
/// toolbar. It renders a repository/worktree tree and pane rows derived from
/// the complete official discovery snapshot, while delegating all lifecycle
/// decisions to RootViewModel.
struct PanePickerView: View {
    let state: PanePickerState
    let onDismiss: () -> Void
    let onRefresh: () async -> Void
    let onCreateWorkspace: () -> Void
    let isCreatingWorkspace: Bool
    let onSelectPane: (Pane.ID) -> Void
    let onSelectOrdinaryTerminal: () -> Void
    let onAppear: () -> Void
    @State private var query = ""
    @State private var filter: PanePickerFilter = .all
    @StateObject private var history = PanePickerHistory()
    @FocusState private var isSearchFocused: Bool

    private var catalog: PanePickerCatalog { PanePickerCatalog(host: state.host, snapshot: state.snapshot) }
    private var matching: [PanePickerCatalog.Entry] { catalog.matching(query: query, filter: filter) }

    var body: some View {
        NavigationStack {
            List {
                if let message = state.message {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(MudiTypography.body(13)).foregroundStyle(MudiPalette.sunset).mudiRow()
                }
                if state.isLoading {
                    ProgressView("正在发现 Herdr…").frame(maxWidth: .infinity, minHeight: 180)
                        .listRowBackground(Color.clear)
                } else if !query.isEmpty {
                    Section {
                        paneRows(matching)
                    } header: {
                        MudiSectionHeader(title: "「\(query)」", count: matching.count)
                    }
                    if matching.isEmpty { emptyResults }
                } else {
                    let favorites = matching.filter { history.isFavorite(hostID: state.host.id, paneID: $0.pane.id) }
                    if !favorites.isEmpty {
                        Section { paneRows(favorites) } header: {
                            MudiSectionHeader(title: "收藏", count: favorites.count, icon: .star)
                        }
                    }
                    let recent = history.recentPaneIDs(hostID: state.host.id).prefix(3).compactMap { id in
                        matching.first { $0.pane.id == id }
                    }
                    if !recent.isEmpty {
                        Section { paneRows(recent) } header: {
                            MudiSectionHeader(title: "最近使用", count: recent.count, icon: .clock)
                        }
                    }
                    let groups = orderedProjectIDs
                    ForEach(groups, id: \.self) { projectID in
                        let rows = matching.filter { $0.projectID == projectID }
                        Section { paneRows(rows) } header: {
                            MudiSectionHeader(title: "按项目 · \(rows.first?.projectTitle ?? "")", count: rows.count, icon: .project)
                        }
                    }
                    if matching.isEmpty { emptyResults }
                }
                if !state.isLoading {
                    Section {
                        Button(action: onSelectOrdinaryTerminal) {
                            HStack(spacing: 12) {
                                MudiIcon.terminal.image.frame(width: 16).foregroundStyle(MudiPalette.mute)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("普通 SSH 终端").font(MudiTypography.body(16, weight: .semibold))
                                    Text(state.host.displayName).font(MudiTypography.mono(12)).foregroundStyle(MudiPalette.mute)
                                }
                                Spacer()
                                Text("Shell").font(MudiTypography.body(13)).foregroundStyle(MudiPalette.mute)
                            }.frame(minHeight: 64)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("pane-picker-ordinary-terminal")
                        .mudiRow()
                    }
                }
            }
            .mudiGroupedList(background: MudiPalette.sheet)
            .safeAreaInset(edge: .top, spacing: 0) { searchAndFilters }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { pickerToolbar }
            .refreshable { await onRefresh() }
        }
        .tint(MudiPalette.ink)
        .onAppear(perform: onAppear)
        .accessibilityIdentifier("pane-picker")
    }

    @ToolbarContentBuilder private var pickerToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            MudiRoundButton(icon: .close, label: "关闭", action: onDismiss)
                .accessibilityIdentifier("pane-picker-close")
        }.mudiToolbarBackground()
        ToolbarItem(placement: .principal) {
            VStack(spacing: 2) {
                Text("选择 Pane").font(MudiTypography.body(17, weight: .semibold)).foregroundStyle(MudiPalette.ink)
                Text("\(state.host.displayName) · \(catalog.rows.count) 个 pane")
                    .font(MudiTypography.mono(12)).foregroundStyle(MudiPalette.mute)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 8) {
                MudiRoundButton(icon: .plus, label: "新建工作区", action: onCreateWorkspace)
                    .disabled(isCreatingWorkspace).accessibilityIdentifier("pane-picker-create-workspace")
                MudiRoundButton(icon: .refresh, label: "刷新", action: { Task { await onRefresh() } })
                    .accessibilityIdentifier("pane-picker-refresh")
            }.fixedSize()
        }.mudiToolbarBackground()
    }

    private var searchAndFilters: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                MudiIcon.search.image.foregroundStyle(MudiPalette.mute)
                TextField("搜索 pane、repo、host…", text: $query)
                    .font(MudiTypography.body()).focused($isSearchFocused)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("pane-picker-search")
                    .overlay(alignment: .leading) {
                        AccessibilityIdentifierBridge(identifier: "pane-picker-search").frame(width: 1, height: 1)
                    }
                if !query.isEmpty {
                    Button { query = "" } label: {
                        MudiIcon.close.image.frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }
                    .accessibilityLabel("清除搜索").buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).frame(minHeight: 44)
            .background(MudiPalette.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(MudiPalette.hairline, lineWidth: 1))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(PanePickerFilter.allCases, id: \.self) { value in
                        Button { filter = value } label: {
                            HStack(spacing: 5) {
                                if value != .all { Circle().fill(filterColor(value)).frame(width: 6, height: 6) }
                                Text(value.title).font(MudiTypography.body(13, weight: .medium))
                                Text("\(catalog.matching(query: query, filter: value).count)").font(MudiTypography.mono(12)).opacity(0.65)
                            }
                            .foregroundStyle(filter == value ? MudiPalette.canvas : MudiPalette.body)
                            .padding(.horizontal, 10).frame(minHeight: 30)
                            .background(filter == value ? MudiPalette.ink : .clear, in: Capsule())
                            .overlay(Capsule().stroke(filter == value ? .clear : MudiPalette.border, lineWidth: 1))
                            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("pane-picker-filter-\(value.rawValue)")
                        .accessibilityAddTraits(filter == value ? .isSelected : [])
                        .overlay(alignment: .leading) {
                            AccessibilityIdentifierBridge(identifier: "pane-picker-filter-\(value.rawValue)", action: { filter = value })
                                .frame(width: 1, height: 1)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 6)
        .background(MudiPalette.sheet)
    }

    private var orderedProjectIDs: [String] {
        var seen = Set<String>()
        return matching.compactMap { seen.insert($0.projectID).inserted ? $0.projectID : nil }
    }
    private var emptyResults: some View {
        ContentUnavailableView(query.isEmpty ? "没有匹配的 Pane" : "没有搜索结果", systemImage: "magnifyingglass", description: Text("试试其他关键词或状态，或打开普通 SSH 终端。"))
            .listRowBackground(Color.clear)
    }
    private func filterColor(_ value: PanePickerFilter) -> Color {
        switch value {
        case .waiting: MudiPalette.sunset
        case .working: MudiPalette.green
        case .all, .done: MudiPalette.dim
        }
    }
    private func paneRows(_ rows: [PanePickerCatalog.Entry]) -> some View {
        ForEach(rows) { entry in
            let current = state.currentPaneID == entry.pane.id
            Button {
                history.recordSelection(hostID: state.host.id, paneID: entry.pane.id)
                onSelectPane(entry.pane.id)
            } label: {
                MudiPaneRow(entry: entry, isFavorite: history.isFavorite(hostID: state.host.id, paneID: entry.pane.id), isCurrent: current)
            }
            .buttonStyle(.plain).mudiRow()
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("pane-picker-pane-\(entry.pane.id)")
            .accessibilityAddTraits(current ? .isSelected : [])
            .accessibilityValue(current ? "Current pane" : "")
            .overlay(alignment: .topLeading) {
                AccessibilityIdentifierBridge(
                    identifier: "pane-picker-pane-\(entry.pane.id)",
                    action: {
                        history.recordSelection(hostID: state.host.id, paneID: entry.pane.id)
                        onSelectPane(entry.pane.id)
                    },
                    accessibilityValue: current ? "Current pane" : nil,
                    accessibilityTraits: current ? [.button, .selected] : [.button]
                ).frame(width: 1, height: 1)
            }
            .contextMenu {
                Button(history.isFavorite(hostID: state.host.id, paneID: entry.pane.id) ? "取消收藏" : "收藏", systemImage: "star") {
                    history.toggleFavorite(hostID: state.host.id, paneID: entry.pane.id)
                }
            }
        }
    }
}

private struct MudiPaneRow: View {
    let entry: PanePickerCatalog.Entry
    let isFavorite: Bool
    let isCurrent: Bool
    var body: some View {
        HStack(spacing: 12) {
            statusIcon.image.foregroundStyle(statusColor).frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.pane.agent?.name ?? entry.pane.title).font(MudiTypography.body(16, weight: .semibold))
                        .foregroundStyle(MudiPalette.ink).fixedSize(horizontal: false, vertical: true)
                    if entry.pane.agent != nil {
                        Text(entry.pane.title).font(MudiTypography.body(15)).foregroundStyle(MudiPalette.body).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text(entry.context).font(MudiTypography.mono(12)).foregroundStyle(MudiPalette.mute).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                if isFavorite { MudiIcon.star.image.foregroundStyle(MudiPalette.mute) }
                if isCurrent { Image(systemName: "checkmark").font(.caption).accessibilityHidden(true) }
                Text(statusTitle).font(MudiTypography.body(13, weight: .medium)).foregroundStyle(statusColor)
            }
        }
        .frame(minHeight: 64)
        .contentShape(Rectangle())
    }
    private var statusIcon: MudiIcon {
        switch entry.pane.agent?.state {
        case .waitingForInput: .statusWaiting
        case .working: .statusWorking
        case .done, .idle, .unknown: .statusDone
        case nil: .terminal
        }
    }
    private var statusColor: Color {
        switch entry.pane.agent?.state {
        case .waitingForInput: MudiPalette.sunset
        case .working: MudiPalette.green
        default: MudiPalette.mute
        }
    }
    private var statusTitle: String {
        switch entry.pane.agent?.state {
        case .waitingForInput: "需要输入"
        case .working: "正在工作"
        case .done: "已完成"
        case .idle: "空闲"
        case .unknown: "未知"
        case nil: "Shell"
        }
    }
}
