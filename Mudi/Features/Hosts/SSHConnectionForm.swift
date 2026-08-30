import HerdrKit
import SwiftUI

/// Edits a saved host. Secrets are never encoded into the Host value; the
/// caller stores the returned credentials in the Keychain.
struct SSHConnectionForm: View {
    let host: Host?
    let onSave: (Host, SSHCredentials?) -> Void
    let onCancel: () -> Void

    @State private var displayName: String
    @State private var hostname: String
    @State private var port: String
    @State private var username: String
    @State private var password: String
    @State private var pemPrivateKey: String
    @State private var preferredTransport: TransportPreference

    private var parsedPort: UInt16? {
        guard let value = UInt16(port), value > 0 else { return nil }
        return value
    }

    private var hasCredentials: Bool {
        !password.isEmpty || !pemPrivateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSave: Bool {
        !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && parsedPort != nil
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (host != nil || hasCredentials)
    }

    init(
        host: Host?,
        credentials: SSHCredentials?,
        onSave: @escaping (Host, SSHCredentials?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.host = host
        self.onSave = onSave
        self.onCancel = onCancel
        _displayName = State(initialValue: host?.displayName ?? "")
        _hostname = State(initialValue: host?.hostname ?? "")
        _port = State(initialValue: String(host?.port ?? 22))
        _username = State(initialValue: host?.username ?? "")
        _password = State(initialValue: credentials?.password ?? "")
        _pemPrivateKey = State(initialValue: credentials?.pemPrivateKey ?? "")
        _preferredTransport = State(initialValue: host?.preferredTransport ?? .automatic)
    }

    var body: some View {
        Form {
            Section {
                TextField("Display name", text: $displayName)
                    .textInputAutocapitalization(.words)

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

                Picker("Preferred transport", selection: $preferredTransport) {
                    ForEach(TransportPreference.allCases, id: \.self) { preference in
                        Text(preference.title).tag(preference)
                    }
                }
            } header: {
                Text("Host")
            }

            Section {
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Text("or private key")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $pemPrivateKey)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 110)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("PEM private key")
            } header: {
                Text("Credentials")
            } footer: {
                if host == nil {
                    Text("A password or OpenSSH private key is required. Secrets are stored only in the system Keychain.")
                } else {
                    Text("Leave both fields blank to keep the saved credential. Secrets are stored only in the system Keychain.")
                }
            }

            if let parsedPort, parsedPort > 0 {
                EmptyView()
            } else {
                Text("Enter a port between 1 and 65535.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .navigationTitle(host == nil ? "Add Host" : "Edit Host")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onCancel)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(!canSave)
                    .accessibilityIdentifier("save-host-button")
            }
        }
    }

    private func save() {
        guard canSave, let port = parsedPort else { return }

        let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHostname = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let savedHost = Host(
            id: host?.id ?? UUID(),
            displayName: trimmedDisplayName,
            hostname: trimmedHostname,
            port: port,
            username: trimmedUsername,
            preferredTransport: preferredTransport
        )

        let trimmedPEM = pemPrivateKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let credentials: SSHCredentials?
        if password.isEmpty && trimmedPEM.isEmpty {
            credentials = nil
        } else {
            credentials = SSHCredentials(
                password: password.isEmpty ? nil : password,
                pemPrivateKey: trimmedPEM.isEmpty ? nil : trimmedPEM
            )
        }
        onSave(savedHost, credentials)
    }
}

private extension TransportPreference {
    var title: String {
        switch self {
        case .automatic:
            "Automatic"
        case .mosh:
            "Mosh"
        case .ssh:
            "SSH"
        }
    }
}
