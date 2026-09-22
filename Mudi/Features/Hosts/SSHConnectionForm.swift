import HerdrKit
import SwiftUI

/// Edits a saved host. Secrets are never encoded into the Host value; the
/// caller stores the returned credentials in the Keychain.
struct SSHConnectionForm: View {
    let host: Host?
    let onSave: (Host, SSHCredentials?) -> Void
    let onCancel: () -> Void

    @State private var displayName: String
    @State private var addressDrafts: [AddressDraft]
    @State private var port: String
    @State private var username: String
    @State private var password: String
    @State private var pemPrivateKey: String
    @State private var preferredTransport: TransportPreference
    @State private var validationMessage: String?

    private var parsedPort: UInt16? {
        guard let value = UInt16(port), value > 0 else { return nil }
        return value
    }

    private var parsedAddresses: [HostAddress]? {
        guard !addressDrafts.isEmpty else { return nil }
        var result: [HostAddress] = []
        result.reserveCapacity(addressDrafts.count)
        for draft in addressDrafts {
            let address = draft.address.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !address.isEmpty else { return nil }
            let labelText = draft.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let overrideText = draft.portOverride
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let portOverride: UInt16?
            if overrideText.isEmpty {
                portOverride = nil
            } else {
                guard let value = UInt16(overrideText), value > 0 else {
                    return nil
                }
                portOverride = value
            }
            result.append(
                HostAddress(
                    address: address,
                    portOverride: portOverride,
                    label: labelText.isEmpty ? nil : labelText
                )
            )
        }
        guard Set(result.map(\.id)).count == result.count else { return nil }
        return result
    }

    private var hasCredentials: Bool {
        !password.isEmpty || !pemPrivateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSave: Bool {
        !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && parsedAddresses != nil
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
        _addressDrafts = State(
            initialValue: (host?.addresses ?? [HostAddress(address: "")]).map {
                AddressDraft(
                    label: $0.label ?? "",
                    address: $0.address,
                    portOverride: $0.portOverride.map(String.init) ?? ""
                )
            }
        )
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
                ForEach($addressDrafts) { $draft in
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Address name (optional)", text: $draft.label)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()

                        HStack {
                            TextField("Hostname or IP address", text: $draft.address)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)

                            if addressDrafts.count > 1 {
                                Button("Remove address", systemImage: "minus.circle", role: .destructive) {
                                    removeAddress(draft.id)
                                }
                                .labelStyle(.iconOnly)
                                .accessibilityLabel("Remove address")
                            }
                        }

                        TextField("Port override (optional)", text: $draft.portOverride)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                    }
                    .padding(.vertical, 2)
                }
                .onMove { source, destination in
                    addressDrafts.move(fromOffsets: source, toOffset: destination)
                }
                .onDelete { offsets in
                    guard addressDrafts.count > offsets.count else { return }
                    addressDrafts.remove(atOffsets: offsets)
                }

                Button("Add address", systemImage: "plus") {
                    addressDrafts.append(
                        AddressDraft(label: "", address: "", portOverride: "")
                    )
                }
                .accessibilityIdentifier("add-host-address-button")
            } header: {
                Text("Addresses")
            } footer: {
                Text("Addresses are tried in this order. Names are display-only. Leave a port override blank to use the shared Host port.")
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

            if parsedPort == nil {
                Text("Enter a port between 1 and 65535.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if parsedAddresses == nil {
                Text("Enter at least one unique address and valid optional port overrides.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if let validationMessage {
                Text(validationMessage)
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
            ToolbarItem(placement: .automatic) {
                EditButton()
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(!canSave)
                    .accessibilityIdentifier("save-host-button")
            }
        }
    }

    private func save() {
        guard canSave, let port = parsedPort, let addresses = parsedAddresses else { return }

        let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let savedHost = Host(
            id: host?.id ?? UUID(),
            displayName: trimmedDisplayName,
            addresses: addresses,
            port: port,
            username: trimmedUsername,
            preferredTransport: preferredTransport
        )
        do {
            try savedHost.validate()
        } catch let error as HostAddressValidationError {
            validationMessage = error.localizedDescription
            return
        } catch {
            validationMessage = error.localizedDescription
            return
        }

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

    private func removeAddress(_ id: AddressDraft.ID) {
        guard addressDrafts.count > 1,
              let index = addressDrafts.firstIndex(where: { $0.id == id })
        else { return }
        addressDrafts.remove(at: index)
    }
}

private struct AddressDraft: Identifiable {
    let id = UUID()
    var label: String
    var address: String
    var portOverride: String

    init(label: String, address: String, portOverride: String) {
        self.label = label
        self.address = address
        self.portOverride = portOverride
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
