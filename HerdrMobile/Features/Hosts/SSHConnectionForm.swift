import HerdrKit
import SwiftUI

struct SSHConnectionForm: View {
    let isConnecting: Bool
    let errorMessage: String?
    let onConnect: (Host, SSHCredentials) -> Void

    @State private var hostname = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var password = ""

    private var parsedPort: UInt16? {
        guard let value = UInt16(port), value > 0 else {
            return nil
        }
        return value
    }

    private var canConnect: Bool {
        !hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && parsedPort != nil
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.isEmpty
            && !isConnecting
    }

    var body: some View {
        Form {
            Section {
                TextField("Hostname or IP address", text: $hostname)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                TextField("Port", text: $port)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)

                TextField("Username", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.username)
            } header: {
                Text("SSH connection")
            }

            Section {
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Credentials")
            } footer: {
                Text("Credentials are used for this connection only and are not saved.")
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("ssh-connection-error")
                }
            }

            Section {
                Button(action: connect) {
                    HStack {
                        Text(isConnecting ? "Connecting…" : "Connect")
                        Spacer()
                        if isConnecting {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.right")
                        }
                    }
                }
                .disabled(!canConnect)
                .accessibilityIdentifier("ssh-connect-button")
            }
        }
        .navigationTitle("Connect to SSH")
    }

    private func connect() {
        guard canConnect, let port = parsedPort else {
            return
        }

        let hostName = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        let userName = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = Host(
            displayName: hostName,
            hostname: hostName,
            port: port,
            username: userName
        )
        let credentials = SSHCredentials(password: password)

        // Do not keep the password in the form once the connection attempt has
        // taken ownership of this one-shot credential value.
        password.removeAll(keepingCapacity: false)
        onConnect(host, credentials)
    }
}
