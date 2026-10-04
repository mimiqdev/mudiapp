import HerdrKit
import SwiftUI

enum HostListSwipeAction: Hashable {
    case edit
    case delete
}

struct HostListSwipeActionDescriptor {
    let action: HostListSwipeAction
    let title: String
    let systemImage: String
    let role: ButtonRole?
    let perform: () -> Void
}

struct HostListActionPolicy: Equatable {
    let swipeActions: [HostListSwipeAction]

    static let current = HostListActionPolicy(swipeActions: [.edit, .delete])

    func swipeActionDescriptors(
        for host: Host,
        onEdit: @escaping (Host) -> Void,
        onDelete: @escaping (Host) -> Void
    ) -> [HostListSwipeActionDescriptor] {
        swipeActions.map { action in
            switch action {
            case .edit:
                HostListSwipeActionDescriptor(
                    action: action,
                    title: "Edit",
                    systemImage: "pencil",
                    role: nil,
                    perform: { onEdit(host) }
                )
            case .delete:
                HostListSwipeActionDescriptor(
                    action: action,
                    title: "Delete",
                    systemImage: "trash",
                    role: .destructive,
                    perform: { onDelete(host) }
                )
            }
        }
    }
}

struct HostListView: View {
    let hosts: [Host]
    let connectionState: ConnectionState
    /// The host with a live model attempt; it keeps the row connecting for the
    /// whole attempt, including the Herdr discovery phase.
    let connectingHostID: Host.ID?
    /// The endpoint currently being tried by the address race. It is transient
    /// and never changes the saved Host order.
    let connectingAddress: HostAddress?
    /// Full transient race status, including concurrently attempted backups
    /// and the elapsed network wait.
    let addressRaceProgress: HostAddressRaceProgress?
    /// Final per-address failures retained on the failed Host row.
    let addressRaceFailure: [HostAddressAttemptResult]?
    /// The host whose last attempt genuinely failed; it keeps the red warning
    /// and Retry even after the coordinator converges to `.disconnected`.
    let failedHostID: Host.ID?
    /// The row that owns `connectionState`; every other row stays idle.
    let stateOwnerHostID: Host.ID?
    let showsConnectCancel: Bool
    let errorMessage: String?
    let onConnect: (Host) -> Void
    let onCancelConnect: () -> Void
    let onReconnect: () -> Void
    let onAdd: () -> Void
    let onEdit: (Host) -> Void
    let onDelete: (Host) -> Void
    let onSettings: () -> Void

    init(
        hosts: [Host],
        connectionState: ConnectionState,
        connectingHostID: Host.ID? = nil,
        connectingAddress: HostAddress? = nil,
        addressRaceProgress: HostAddressRaceProgress? = nil,
        addressRaceFailure: [HostAddressAttemptResult]? = nil,
        failedHostID: Host.ID? = nil,
        stateOwnerHostID: Host.ID? = nil,
        showsConnectCancel: Bool = false,
        errorMessage: String?,
        onConnect: @escaping (Host) -> Void,
        onCancelConnect: @escaping () -> Void = {},
        onReconnect: @escaping () -> Void,
        onAdd: @escaping () -> Void,
        onEdit: @escaping (Host) -> Void,
        onDelete: @escaping (Host) -> Void,
        onSettings: @escaping () -> Void = {}
    ) {
        self.hosts = hosts
        self.connectionState = connectionState
        self.connectingHostID = connectingHostID
        self.connectingAddress = connectingAddress
        self.addressRaceProgress = addressRaceProgress
        self.addressRaceFailure = addressRaceFailure
        self.failedHostID = failedHostID
        self.stateOwnerHostID = stateOwnerHostID
        self.showsConnectCancel = showsConnectCancel
        self.errorMessage = errorMessage
        self.onConnect = onConnect
        self.onCancelConnect = onCancelConnect
        self.onReconnect = onReconnect
        self.onAdd = onAdd
        self.onEdit = onEdit
        self.onDelete = onDelete
        self.onSettings = onSettings
    }

    var body: some View {
        List {
            if hosts.isEmpty {
                ContentUnavailableView {
                    Label("添加第一台主机", systemImage: "server.rack")
                } description: {
                    Text("保存 SSH 地址，随时进入你的终端。")
                } actions: {
                    Button("添加主机", action: onAdd).buttonStyle(MudiPillStyle(filled: true))
                }
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(hosts) { host in
                        hostRow(host)
                            .mudiRow()
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 14))
                    }
                } header: {
                    MudiSectionHeader(title: "已保存", count: hosts.count)
                }
            }
        }
        .mudiGroupedList()
        .navigationTitle("主机")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 8) {
                    MudiRoundButton(icon: .plus, label: "添加主机", action: onAdd)
                    MudiRoundButton(icon: .settings, label: "设置", action: onSettings)
                }.fixedSize()
            }.mudiToolbarBackground()
        }
        .safeAreaInset(edge: .bottom) {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(MudiTypography.body(12))
                    .foregroundStyle(MudiPalette.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(MudiPalette.canvas)
                    .accessibilityIdentifier("ssh-connection-error")
            }
        }
    }

    private func hostRow(_ host: Host) -> some View {
        let state = HostRowConnectionState.resolve(
            host: host, connectingHostID: connectingHostID,
            failedHostID: failedHostID, stateOwnerHostID: stateOwnerHostID,
            connectionState: connectionState
        )
        let presentation = HostRowConnectionPresentation.resolve(state: state, showsCancel: showsConnectCancel)
        return HStack(spacing: 12) {
            status(presentation, host: host)
                .frame(width: 16, height: 16)
            Button { if presentation.canConnect { onConnect(host) } } label: {
                HostRow(
                    host: host,
                    displayedAddress: host.id == stateOwnerHostID || host.id == connectingHostID ? connectingAddress : nil,
                    raceProgress: host.id == connectingHostID ? addressRaceProgress : nil,
                    raceFailure: host.id == failedHostID ? addressRaceFailure : nil,
                    isConnecting: presentation.isConnecting,
                    isFailed: presentation.showsFailure
                )
            }
            .buttonStyle(.plain)
            .allowsHitTesting(presentation.canConnect)
            .accessibilityIdentifier("host-connect-\(host.id.uuidString)")
            .overlay(alignment: .topLeading) {
                AccessibilityIdentifierBridge(identifier: "host-connect-\(host.id.uuidString)", action: { if presentation.canConnect { onConnect(host) } })
                    .frame(width: 1, height: 1)
            }
            if presentation.showsCancel {
                Button("取消", role: .cancel, action: onCancelConnect)
                    .buttonStyle(MudiPillStyle())
                    .accessibilityIdentifier("host-cancel-\(host.id.uuidString)")
                    .overlay(alignment: .topLeading) {
                        AccessibilityIdentifierBridge(identifier: "host-cancel-\(host.id.uuidString)", action: onCancelConnect)
                            .frame(width: 1, height: 1)
                    }
            } else if presentation.showsRetry {
                Button(action: onReconnect) {
                    HStack(spacing: 5) { MudiIcon.retry.image; Text("重试") }
                }
                .buttonStyle(MudiPillStyle())
                .accessibilityIdentifier("host-retry-\(host.id.uuidString)")
                .overlay(alignment: .topLeading) {
                    AccessibilityIdentifierBridge(identifier: "host-retry-\(host.id.uuidString)", action: onReconnect)
                        .frame(width: 1, height: 1)
                }
            } else if presentation.showsConnected {
                Text("已连接").font(MudiTypography.body(13)).foregroundStyle(MudiPalette.green)
                Menu {
                    Button("进入会话") { onConnect(host) }
                    Button("编辑主机", systemImage: "pencil") { onEdit(host) }
                    Button("删除主机", systemImage: "trash", role: .destructive) { onDelete(host) }
                } label: {
                    MudiIcon.ellipsis.image
                        .frame(width: 30, height: 30)
                        .background(MudiPalette.raised, in: Circle())
                        .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("主机操作")
            } else if state == .idle {
                MudiIcon.chevronRight.image.foregroundStyle(MudiPalette.dim)
            }
        }
        .frame(minHeight: 62)
        .contextMenu {
            Button("编辑主机", systemImage: "pencil") { onEdit(host) }
            Button("删除主机", systemImage: "trash", role: .destructive) { onDelete(host) }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            ForEach(HostListActionPolicy.current.swipeActionDescriptors(for: host, onEdit: onEdit, onDelete: onDelete), id: \.action) { action in
                Button(action.title, systemImage: action.systemImage, role: action.role, action: action.perform)
            }
        }
    }

    @ViewBuilder
    private func status(_ presentation: HostRowConnectionPresentation, host: Host) -> some View {
        if presentation.showsProgress {
            ProgressView().controlSize(.small).tint(MudiPalette.ink)
                .accessibilityIdentifier("host-connecting-\(host.id.uuidString)")
                .overlay {
                    AccessibilityIdentifierBridge(identifier: "host-connecting-\(host.id.uuidString)").frame(width: 1, height: 1)
                }
        } else {
            let icon: MudiIcon = presentation.showsConnected ? .statusWorking : presentation.showsFailure ? .statusFailed : .statusIdle
            icon.image
                .foregroundStyle(presentation.showsConnected ? MudiPalette.green : presentation.showsFailure ? MudiPalette.red : MudiPalette.mute)
                .accessibilityLabel(presentation.showsConnected ? "Connected" : presentation.showsFailure ? "Connection failed" : "Not connected")
                .overlay {
                    if presentation.showsConnected || presentation.showsFailure {
                        AccessibilityIdentifierBridge(identifier: "host-\(presentation.showsConnected ? "connected" : "failed")-\(host.id.uuidString)")
                            .frame(width: 1, height: 1)
                    }
                }
        }
    }
}

func hostAddressProgressText(_ address: HostAddress, defaultPort: UInt16) -> String {
    let endpoint = "\(address.address):\(address.effectivePort(defaultPort: defaultPort))"
    guard let label = address.label else { return endpoint }
    return "\(label) · \(endpoint)"
}

private extension HostAddressRaceProgress {
    func detailText(defaultPort: UInt16) -> String? {
        switch self {
        case let .preferred(address, elapsed):
            return "Trying \(hostAddressProgressText(address, defaultPort: defaultPort)) · \(elapsedText(elapsed))"
        case let .racing(addresses, elapsed):
            let targets = addresses
                .map { hostAddressProgressText($0, defaultPort: defaultPort) }
                .joined(separator: ", ")
            return "Trying \(targets) · \(elapsedText(elapsed))"
        case let .selected(address, elapsed):
            return "Authenticating \(hostAddressProgressText(address, defaultPort: defaultPort)) · \(elapsedText(elapsed))"
        case let .failed(outcomes):
            let failures = outcomes.compactMap { outcome -> String? in
                let address = hostAddressProgressText(
                    outcome.address,
                    defaultPort: defaultPort
                )
                switch outcome.outcome {
                case let .failed(message):
                    return "\(address): \(message)"
                case .timedOut:
                    return "\(address): timed out"
                case .cancelled:
                    return "\(address): cancelled"
                case .notStarted:
                    return "\(address): not started"
                case .started, .succeeded:
                    return nil
                }
            }
            return failures.isEmpty ? nil : failures.joined(separator: " · ")
        }
    }

    private func elapsedText(_ elapsed: Duration) -> String {
        let seconds = elapsed.components.seconds
        return seconds == 0 ? "<1s" : "\(seconds)s"
    }
}

private struct HostRow: View {
    let host: Host
    let displayedAddress: HostAddress?
    let raceProgress: HostAddressRaceProgress?
    let raceFailure: [HostAddressAttemptResult]?
    let isConnecting: Bool
    let isFailed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(host.displayName).font(MudiTypography.body(17, weight: .semibold))
                if isConnecting {
                    Text("连接中…").font(MudiTypography.body(13)).foregroundStyle(MudiPalette.mute)
                }
            }
            .foregroundStyle(MudiPalette.ink)
            let target = displayedAddress ?? host.selectedTarget ?? host.addresses.first
            let address = target?.address ?? host.hostname
            let port = target?.effectivePort(defaultPort: host.port) ?? host.port
            Text("\(address)\(port == 22 ? "" : ":\(port)")\(host.addresses.count > 1 && !isConnecting ? " +\(host.addresses.count - 1)" : "") · \(transportTitle)")
                .font(MudiTypography.mono()).foregroundStyle(isFailed ? MudiPalette.red : MudiPalette.mute)
                .fixedSize(horizontal: false, vertical: true)
            if let raceProgress, let detail = raceProgress.detailText(defaultPort: host.port) {
                Text(detail).font(MudiTypography.mono(11)).foregroundStyle(MudiPalette.mute).fixedSize(horizontal: false, vertical: true)
            } else if let raceFailure, let detail = HostAddressRaceProgress.failed(outcomes: raceFailure).detailText(defaultPort: host.port) {
                Text(detail).font(MudiTypography.body(11)).foregroundStyle(MudiPalette.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 11)
        .opacity(isFailed ? 0.7 : 1)
        .contentShape(Rectangle())
    }
    private var transportTitle: String {
        switch host.preferredTransport {
        case .automatic: "Auto"
        case .mosh: "Mosh"
        case .ssh: "SSH"
        }
    }
}
