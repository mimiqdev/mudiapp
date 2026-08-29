import HerdrKit
import SwiftUI

struct RootView: View {
    @State private var activeConnection: ActiveSSHConnection?
    @State private var isConnecting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if let activeConnection {
                    TerminalScreen(
                        host: activeConnection.host,
                        session: activeConnection.session,
                        onDisconnect: disconnect
                    )
                } else {
                    SSHConnectionForm(
                        isConnecting: isConnecting,
                        errorMessage: errorMessage,
                        onConnect: connect
                    )
                }
            }
        }
    }

    private func connect(to host: Host, credentials: SSHCredentials) {
        guard !isConnecting else { return }

        errorMessage = nil
        isConnecting = true
        let session = SSHShellSession(client: CitadelSSHAdapter())

        Task {
            do {
                try await session.connect(to: host, credentials: credentials)
                activeConnection = ActiveSSHConnection(host: host, session: session)
                isConnecting = false
            } catch let error as SSHShellError {
                await session.disconnect()
                errorMessage = error.errorDescription ?? "Unable to connect to the SSH host."
                isConnecting = false
            } catch {
                await session.disconnect()
                errorMessage = "Unable to connect to the SSH host."
                isConnecting = false
            }
        }
    }

    private func disconnect() {
        let session = activeConnection?.session
        activeConnection = nil
        errorMessage = nil
        Task {
            await session?.disconnect()
        }
    }
}

private struct ActiveSSHConnection {
    let host: Host
    let session: SSHShellSession
}
