import HerdrKit
import SwiftUI

@MainActor
final class RootViewModel: ObservableObject {
    @Published private(set) var hosts: [Host] = []
    @Published private(set) var activeConnection: ActiveSSHConnection?
    @Published private(set) var connectionState: ConnectionState = .idle
    @Published var errorMessage: String?
    @Published var editor: HostEditorContext?
    @Published var hostKeyPrompt: HostKeyPrompt?

    let coordinator: ApplicationCoordinator
    private var pendingHostKeyDecision: CheckedContinuation<HostKeyDecision, Never>?
    private var stateTask: Task<Void, Never>?
    private var lastHost: Host?

    init(coordinator: ApplicationCoordinator = ApplicationCoordinator()) {
        self.coordinator = coordinator
        stateTask = Task { [weak self, coordinator] in
            let stream = await coordinator.connectionStateStream()
            for await state in stream {
                guard !Task.isCancelled else { return }
                self?.connectionState = state
            }
        }
    }

    deinit {
        stateTask?.cancel()
        pendingHostKeyDecision?.resume(returning: .reject)
    }

    func loadHosts() async {
        do {
            hosts = try await coordinator.loadHosts()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addHost() {
        editor = HostEditorContext(host: nil, credentials: nil)
    }

    func edit(_ host: Host) {
        Task {
            do {
                let credentials = try await coordinator.credentials(for: host)
                editor = HostEditorContext(host: host, credentials: credentials)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancelEditing() {
        editor = nil
    }

    func save(host: Host, credentials: SSHCredentials?) {
        editor = nil
        Task {
            do {
                try await coordinator.save(host)
                if let credentials {
                    try await coordinator.save(credentials, for: host)
                }
                hosts = try await coordinator.loadHosts()
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func delete(_ host: Host) {
        Task {
            do {
                try await coordinator.delete(host)
                hosts = try await coordinator.loadHosts()
                if lastHost?.id == host.id {
                    lastHost = nil
                }
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func connect(to host: Host) {
        guard connectionState != .connecting else { return }

        lastHost = host
        errorMessage = nil
        connectionState = .connecting
        Task {
            do {
                guard let credentials = try await coordinator.credentials(for: host) else {
                    throw MissingCredentialsError()
                }
                let state = try await coordinator.connect(
                    to: host,
                    credentials: credentials,
                    hostKeyDecision: { fingerprint in
                        await self.requestHostKeyDecision(for: fingerprint)
                    }
                )
                guard state == .connected,
                      let session = await coordinator.activeShellSession()
                else {
                    throw ConnectionError.connectionFailed
                }
                activeConnection = ActiveSSHConnection(host: host, session: session)
                connectionState = state
            } catch {
                activeConnection = nil
                connectionState = (await coordinator.connectionState())
                errorMessage = error.localizedDescription
            }
        }
    }

    func reconnect() {
        guard connectionState != .connecting, lastHost != nil else { return }

        errorMessage = nil
        connectionState = .connecting
        Task {
            do {
                let state = try await coordinator.reconnect()
                guard state == .connected,
                      let host = lastHost,
                      let session = await coordinator.activeShellSession()
                else {
                    throw ConnectionError.connectionFailed
                }
                activeConnection = ActiveSSHConnection(host: host, session: session)
                connectionState = state
            } catch {
                activeConnection = nil
                connectionState = await coordinator.connectionState()
                errorMessage = error.localizedDescription
            }
        }
    }

    func disconnect() {
        answerHostKeyPrompt(.reject)
        activeConnection = nil
        Task {
            await coordinator.disconnect()
            connectionState = await coordinator.connectionState()
        }
    }

    func requestHostKeyDecision(for fingerprint: String) async -> HostKeyDecision {
        await withCheckedContinuation { continuation in
            pendingHostKeyDecision = continuation
            hostKeyPrompt = HostKeyPrompt(fingerprint: fingerprint)
        }
    }

    func answerHostKeyPrompt(_ decision: HostKeyDecision) {
        guard let pendingHostKeyDecision else { return }
        self.pendingHostKeyDecision = nil
        hostKeyPrompt = nil
        pendingHostKeyDecision.resume(returning: decision)
    }

    private struct MissingCredentialsError: LocalizedError {
        var errorDescription: String? {
            "No saved SSH credentials. Edit this host to add a password or private key."
        }
    }
}

struct HostKeyPrompt: Identifiable, Equatable {
    let id = UUID()
    let fingerprint: String
}

struct HostEditorContext: Identifiable {
    let id: UUID
    let host: Host?
    let credentials: SSHCredentials?

    init(host: Host?, credentials: SSHCredentials?) {
        id = host?.id ?? UUID()
        self.host = host
        self.credentials = credentials
    }
}

struct RootView: View {
    @StateObject private var model: RootViewModel

    init(coordinator: ApplicationCoordinator = ApplicationCoordinator()) {
        _model = StateObject(wrappedValue: RootViewModel(coordinator: coordinator))
    }

    var body: some View {
        NavigationStack {
            Group {
                if let activeConnection = model.activeConnection {
                    TerminalScreen(
                        host: activeConnection.host,
                        session: activeConnection.session,
                        onDisconnect: model.disconnect
                    )
                } else {
                    HostListView(
                        hosts: model.hosts,
                        connectionState: model.connectionState,
                        errorMessage: model.errorMessage,
                        onConnect: model.connect,
                        onReconnect: model.reconnect,
                        onAdd: model.addHost,
                        onEdit: model.edit,
                        onDelete: model.delete
                    )
                }
            }
        }
        .task {
            await model.loadHosts()
        }
        .sheet(item: $model.editor) { context in
            NavigationStack {
                SSHConnectionForm(
                    host: context.host,
                    credentials: context.credentials,
                    onSave: model.save,
                    onCancel: model.cancelEditing
                )
            }
        }
        .alert(item: $model.hostKeyPrompt) { prompt in
            Alert(
                title: Text("Verify SSH host key"),
                message: Text(
                    "The server presented this fingerprint:\n\n\(prompt.fingerprint)\n\nAccept only if it matches a fingerprint you trust."
                ),
                primaryButton: .destructive(Text("Reject")) {
                    model.answerHostKeyPrompt(.reject)
                },
                secondaryButton: .default(Text("Accept")) {
                    model.answerHostKeyPrompt(.accept)
                }
            )
        }
    }
}

struct ActiveSSHConnection {
    let host: Host
    let session: SSHShellSession
}
