import Foundation
import HerdrKit

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

struct ActiveSSHConnection {
    let host: Host
    let session: SSHShellSession
    let terminalTitle: String?
    let transport: ActiveTransport

    init(
        host: Host,
        session: SSHShellSession,
        terminalTitle: String? = nil,
        transport: ActiveTransport = .ssh
    ) {
        self.host = host
        self.session = session
        self.terminalTitle = terminalTitle
        self.transport = transport
    }
}
