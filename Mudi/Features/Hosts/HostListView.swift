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

    static let current = HostListActionPolicy(swipeActions: [.delete])

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
    let errorMessage: String?
    let onConnect: (Host) -> Void
    let onReconnect: () -> Void
    let onAdd: () -> Void
    let onEdit: (Host) -> Void
    let onDelete: (Host) -> Void
    let onSettings: () -> Void

    init(
        hosts: [Host],
        connectionState: ConnectionState,
        errorMessage: String?,
        onConnect: @escaping (Host) -> Void,
        onReconnect: @escaping () -> Void,
        onAdd: @escaping () -> Void,
        onEdit: @escaping (Host) -> Void,
        onDelete: @escaping (Host) -> Void,
        onSettings: @escaping () -> Void = {}
    ) {
        self.hosts = hosts
        self.connectionState = connectionState
        self.errorMessage = errorMessage
        self.onConnect = onConnect
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
                    if connectionState != .idle {
                        Section {
                            HStack {
                                connectionStateLabel
                                Spacer()
                                if connectionState == .failed || connectionState == .disconnected {
                                    Button("Reconnect", action: onReconnect)
                                        .buttonStyle(.bordered)
                                }
                            }
                        }
                    }

                    ForEach(hosts) { host in
                        Button {
                            onConnect(host)
                        } label: {
                            HostRow(host: host)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("host-connect-\(host.id.uuidString)")
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
    private var connectionStateLabel: some View {
        switch connectionState {
        case .idle:
            EmptyView()
        case .connecting:
            Label("Connecting…", systemImage: "arrow.triangle.2.circlepath")
        case .connected:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Label("Connection failed", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        case .disconnected:
            Label("Disconnected", systemImage: "wifi.slash")
                .foregroundStyle(.secondary)
        }
    }
}

private struct HostRow: View {
    let host: Host

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
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
    }
}
