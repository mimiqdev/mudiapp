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
    private var pendingHostKeyPromptID: UUID?
    private var stateTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var connectionGeneration = UUID()
    private var lastHostID: Host.ID?

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
        connectionTask?.cancel()
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
        let deletesActiveConnection = lastHostID == host.id
            || activeConnection?.host.id == host.id
        if deletesActiveConnection {
            invalidateConnectionAttempt()
            activeConnection = nil
            lastHostID = nil
        }

        Task {
            do {
                try await coordinator.delete(host)
                hosts = try await coordinator.loadHosts()
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func connect(to host: Host) {
        guard connectionState != .connecting, connectionState != .connected else { return }

        let generation = beginConnection(for: host.id)
        errorMessage = nil
        connectionState = .connecting
        let coordinator = self.coordinator
        connectionTask = Task { [weak self, coordinator] in
            do {
                guard let credentials = try await coordinator.credentials(for: host) else {
                    throw MissingCredentialsError()
                }
                let state = try await coordinator.connect(
                    to: host,
                    credentials: credentials,
                    hostKeyDecision: { [weak self] fingerprint in
                        guard let self else { return .reject }
                        return await self.requestHostKeyDecision(
                            for: fingerprint,
                            generation: generation
                        )
                    }
                )
                guard let self,
                      self.isCurrentConnection(generation),
                      !Task.isCancelled
                else {
                    await coordinator.disconnect()
                    return
                }
                guard state == .connected,
                      let session = await coordinator.activeShellSession()
                else {
                    throw ConnectionError.connectionFailed
                }
                self.activeConnection = ActiveSSHConnection(host: host, session: session)
                self.connectionState = state
                self.connectionTask = nil
            } catch {
                guard let self, self.isCurrentConnection(generation) else { return }
                self.answerHostKeyPrompt(.reject)
                self.activeConnection = nil
                self.connectionTask = nil
                self.connectionState = await coordinator.connectionState()
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func reconnect() {
        guard connectionState != .connecting,
              connectionState != .connected,
              let hostID = lastHostID
        else { return }

        let generation = beginConnection(for: hostID)
        errorMessage = nil
        connectionState = .connecting
        let coordinator = self.coordinator
        connectionTask = Task { [weak self, coordinator] in
            do {
                let refreshedHosts = try await coordinator.loadHosts()
                guard let self,
                      self.isCurrentConnection(generation),
                      let host = refreshedHosts.first(where: { $0.id == hostID })
                else {
                    throw ConnectionError.connectionFailed
                }
                self.hosts = refreshedHosts

                let state = try await coordinator.reconnect(
                    hostKeyDecision: { [weak self] fingerprint in
                        guard let self else { return .reject }
                        return await self.requestHostKeyDecision(
                            for: fingerprint,
                            generation: generation
                        )
                    }
                )
                guard self.isCurrentConnection(generation),
                      !Task.isCancelled,
                      state == .connected,
                      let session = await coordinator.activeShellSession()
                else {
                    await coordinator.disconnect()
                    return
                }
                self.activeConnection = ActiveSSHConnection(host: host, session: session)
                self.connectionState = state
                self.connectionTask = nil
            } catch {
                guard let self, self.isCurrentConnection(generation) else { return }
                self.answerHostKeyPrompt(.reject)
                self.activeConnection = nil
                self.connectionTask = nil
                self.connectionState = await coordinator.connectionState()
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func disconnect() {
        invalidateConnectionAttempt()
        activeConnection = nil
        let generation = connectionGeneration
        Task {
            await coordinator.disconnect()
            guard connectionGeneration == generation else { return }
            connectionState = await coordinator.connectionState()
        }
    }

    func requestHostKeyDecision(
        for fingerprint: String,
        generation: UUID
    ) async -> HostKeyDecision {
        guard connectionGeneration == generation,
              connectionState == .connecting
        else {
            return .reject
        }

        return await withCheckedContinuation { continuation in
            guard connectionGeneration == generation,
                  connectionState == .connecting
            else {
                continuation.resume(returning: .reject)
                return
            }
            pendingHostKeyDecision?.resume(returning: .reject)
            pendingHostKeyDecision = continuation
            let prompt = HostKeyPrompt(fingerprint: fingerprint)
            pendingHostKeyPromptID = prompt.id
            hostKeyPrompt = prompt
        }
    }

    func answerHostKeyPrompt(_ decision: HostKeyDecision, for promptID: UUID? = nil) {
        guard promptID == nil || promptID == pendingHostKeyPromptID else { return }
        guard let pendingHostKeyDecision else {
            hostKeyPrompt = nil
            pendingHostKeyPromptID = nil
            return
        }
        self.pendingHostKeyDecision = nil
        pendingHostKeyPromptID = nil
        hostKeyPrompt = nil
        pendingHostKeyDecision.resume(returning: decision)
    }

    private func beginConnection(for hostID: Host.ID) -> UUID {
        invalidateConnectionAttempt()
        lastHostID = hostID
        activeConnection = nil
        connectionGeneration = UUID()
        return connectionGeneration
    }

    private func invalidateConnectionAttempt() {
        connectionGeneration = UUID()
        connectionTask?.cancel()
        connectionTask = nil
        answerHostKeyPrompt(.reject)
    }

    private func isCurrentConnection(_ generation: UUID) -> Bool {
        connectionGeneration == generation
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
                    model.answerHostKeyPrompt(.reject, for: prompt.id)
                },
                secondaryButton: .default(Text("Accept")) {
                    model.answerHostKeyPrompt(.accept, for: prompt.id)
                }
            )
        }
    }
}

struct ActiveSSHConnection {
    let host: Host
    let session: SSHShellSession
}
