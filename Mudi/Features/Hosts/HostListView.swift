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
        Group {
            if hosts.isEmpty {
                ContentUnavailableView {
                    Label("No Saved Hosts", systemImage: "externaldrive")
                } description: {
                    Text("Save an SSH host to connect without filling in the form again.")
                } actions: {
                    Button("Add Host", systemImage: "plus", action: onAdd)
                }
            } else {
                List {
                    ForEach(hosts) { host in
                        let presentation = HostRowConnectionPresentation.resolve(
                            state: HostRowConnectionState.resolve(
                                host: host,
                                connectingHostID: connectingHostID,
                                stateOwnerHostID: stateOwnerHostID,
                                connectionState: connectionState
                            ),
                            showsCancel: showsConnectCancel
                        )
                        HStack(spacing: 10) {
                            Button {
                                onConnect(host)
                            } label: {
                                HostRow(
                                    host: host,
                                    showsChevron: presentation.state == .idle
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(!presentation.canConnect)
                            .accessibilityIdentifier(
                                "host-connect-\(host.id.uuidString)"
                            )
                            .overlay(alignment: .topLeading) {
                                AccessibilityIdentifierBridge(
                                    identifier: "host-connect-\(host.id.uuidString)",
                                    action: { onConnect(host) }
                                )
                                .frame(width: 1, height: 1)
                            }

                            // The indeterminate progress view is the row's
                            // visible connecting animation; it is present
                            // exactly while the attempt is published.
                            if presentation.showsProgress {
                                ProgressView()
                                    .controlSize(.small)
                                    .accessibilityIdentifier(
                                        "host-connecting-\(host.id.uuidString)"
                                    )
                                    .overlay(alignment: .topLeading) {
                                        AccessibilityIdentifierBridge(
                                            identifier: "host-connecting-\(host.id.uuidString)"
                                        )
                                        .frame(width: 1, height: 1)
                                    }
                            }

                            // The cancel affordance is revealed only after
                            // the attempt outlives the threshold.
                            if presentation.showsCancel {
                                Button(
                                    "Cancel",
                                    role: .cancel,
                                    action: onCancelConnect
                                )
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier(
                                    "host-cancel-\(host.id.uuidString)"
                                )
                                .overlay(alignment: .topLeading) {
                                    AccessibilityIdentifierBridge(
                                        identifier: "host-cancel-\(host.id.uuidString)",
                                        action: onCancelConnect
                                    )
                                    .frame(width: 1, height: 1)
                                }
                            }

                            // The result states replace the former global
                            // banner: connected, failed, and disconnected all
                            // render on the owning row.
                            if presentation.showsConnected {
                                stateIndicator(
                                    systemImage: "checkmark.circle.fill",
                                    tint: .green,
                                    label: "Connected",
                                    identifier: "host-connected-\(host.id.uuidString)"
                                )
                            }

                            if presentation.showsFailure {
                                stateIndicator(
                                    systemImage: "exclamationmark.triangle.fill",
                                    tint: .red,
                                    label: "Connection failed",
                                    identifier: "host-failed-\(host.id.uuidString)"
                                )
                            }

                            if presentation.showsDisconnected {
                                stateIndicator(
                                    systemImage: "wifi.slash",
                                    tint: .secondary,
                                    label: "Disconnected",
                                    identifier: "host-disconnected-\(host.id.uuidString)"
                                )
                            }

                            // The old banner owned Reconnect; the row keeps
                            // that retry path for failed/disconnected hosts.
                            if presentation.showsRetry {
                                Button("Retry", action: onReconnect)
                                    .buttonStyle(.bordered)
                                    .accessibilityIdentifier(
                                        "host-retry-\(host.id.uuidString)"
                                    )
                                    .overlay(alignment: .topLeading) {
                                        AccessibilityIdentifierBridge(
                                            identifier: "host-retry-\(host.id.uuidString)",
                                            action: onReconnect
                                        )
                                        .frame(width: 1, height: 1)
                                    }
                            }
                        }
                        .contextMenu {
                            Button("Edit", systemImage: "pencil") {
                                onEdit(host)
                            }
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                onDelete(host)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            let actions = HostListActionPolicy.current
                                .swipeActionDescriptors(
                                    for: host,
                                    onEdit: onEdit,
                                    onDelete: onDelete
                                )
                            ForEach(actions, id: \.action) { action in
                                Button(
                                    action.title,
                                    systemImage: action.systemImage,
                                    role: action.role,
                                    action: action.perform
                                )
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Hosts")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Settings", systemImage: "gearshape", action: onSettings)
                Button("Add Host", systemImage: "plus", action: onAdd)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.thinMaterial)
                    .accessibilityIdentifier("ssh-connection-error")
            }
        }
    }

    @ViewBuilder
    private func stateIndicator(
        systemImage: String,
        tint: Color,
        label: String,
        identifier: String
    ) -> some View {
        Image(systemName: systemImage)
            .foregroundStyle(tint)
            .accessibilityLabel(label)
            .accessibilityIdentifier(identifier)
            .overlay(alignment: .topLeading) {
                AccessibilityIdentifierBridge(identifier: identifier)
                    .frame(width: 1, height: 1)
            }
    }
}

private struct HostRow: View {
    let host: Host
    var showsChevron = true

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .foregroundStyle(.tint)
                .imageScale(.large)

            VStack(alignment: .leading, spacing: 3) {
                Text(host.displayName)
                    .font(.headline)
                Text("\(host.username)@\(host.hostname):\(host.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
            // The chevron yields its slot to the row's state accessory, so
            // the trailing area keeps a stable width.
            if showsChevron {
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
    }
}
