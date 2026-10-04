import HerdrKit
import SwiftUI

/// Edits a saved host. Secrets are never encoded into the Host value; the
/// caller stores the returned credentials in the Keychain.
struct SSHConnectionForm: View {
    let host: Host?
    let onSave: (Host, SSHCredentials?) -> Void
    let onCancel: () -> Void
    var addressPromotion: Binding<Bool>
    @State private var editingAddressID: UUID?

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
        onCancel: @escaping () -> Void,
        addressPromotion: Binding<Bool> = .constant(false)
    ) {
        self.host = host
        self.onSave = onSave
        self.onCancel = onCancel
        self.addressPromotion = addressPromotion
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
                field("名称", text: $displayName)
                    .textInputAutocapitalization(.words)
                field("用户名", text: $username, mono: true)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(.username)
                field("端口", text: $port, mono: true)
                    .keyboardType(.numberPad).textContentType(.oneTimeCode)
            } header: { MudiSectionHeader(title: "主机") }
            .mudiRow()

            Section {
                ForEach(addressDrafts) { draft in
                    HStack(spacing: 10) {
                        MudiIcon.grip.image.foregroundStyle(MudiPalette.dim)
                            .draggable(draft.id.uuidString)
                            .accessibilityLabel("拖动排序地址")
                        Button { editingAddressID = draft.id } label: {
                            HStack(spacing: 10) {
                                Text(draft.label.isEmpty ? "地址" : draft.label)
                                    .font(MudiTypography.mono(11)).foregroundStyle(MudiPalette.body)
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(MudiPalette.border, lineWidth: 1))
                                Text(draft.address.isEmpty ? "主机名或 IP" : draft.address)
                                    .font(MudiTypography.mono(15)).foregroundStyle(draft.address.isEmpty ? MudiPalette.mute : MudiPalette.ink)
                                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                if !draft.portOverride.isEmpty {
                                    Text(":\(draft.portOverride)").font(MudiTypography.mono(12)).foregroundStyle(MudiPalette.mute)
                                }
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Button { removeAddress(draft.id) } label: {
                            MudiIcon.minus.image.foregroundStyle(MudiPalette.mute)
                        }.buttonStyle(.plain).disabled(addressDrafts.count <= 1).accessibilityLabel("移除地址")
                    }
                    .frame(minHeight: 50)
                    .dropDestination(for: String.self) { items, _ in
                        guard let value = items.first, let id = UUID(uuidString: value),
                              let source = addressDrafts.firstIndex(where: { $0.id == id }),
                              let target = addressDrafts.firstIndex(where: { $0.id == draft.id }), source != target else { return false }
                        addressDrafts.move(fromOffsets: IndexSet(integer: source), toOffset: target > source ? target + 1 : target)
                        return true
                    }
                    .accessibilityAction(named: "向上移动") { moveAddress(draft.id, by: -1) }
                    .accessibilityAction(named: "向下移动") { moveAddress(draft.id, by: 1) }
                }
                .onMove { addressDrafts.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { offsets in
                    guard addressDrafts.count > offsets.count else { return }
                    addressDrafts.remove(atOffsets: offsets)
                }
                Button {
                    let draft = AddressDraft(label: "", address: "", portOverride: "")
                    addressDrafts.append(draft)
                    editingAddressID = draft.id
                } label: {
                    HStack(spacing: 10) { MudiIcon.plus.image; Text("添加地址") }
                }.accessibilityIdentifier("add-host-address-button")
            } header: {
                HStack { Text("地址"); Spacer(); Text("按顺序尝试").font(MudiTypography.body(12)) }
                    .font(MudiTypography.body(13)).foregroundStyle(MudiPalette.mute).textCase(nil)
            } footer: {
                Text("名称仅用于显示；端口留空则使用主机端口。")
                    .font(MudiTypography.body(12)).foregroundStyle(MudiPalette.mute)
            }
            .mudiRow()

            Section {
                Toggle(isOn: addressPromotion) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("智能提升")
                        Text("优先尝试上次成功的地址，不改动保存的顺序")
                            .font(MudiTypography.body(12)).foregroundStyle(MudiPalette.mute)
                    }
                }.accessibilityIdentifier("host-address-promotion-toggle")
            }.mudiRow()

            Section {
                Picker("连接方式", selection: $preferredTransport) {
                    ForEach(TransportPreference.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
            } header: { MudiSectionHeader(title: "连接方式") } footer: {
                Text("Auto：SSH 引导后优先 Mosh，不可用时回退 SSH。")
                    .font(MudiTypography.body(12)).foregroundStyle(MudiPalette.mute)
            }.mudiRow()

            Section {
                NavigationLink {
                    Form {
                        Section {
                            TextEditor(text: $pemPrivateKey)
                                .font(MudiTypography.mono(13)).frame(minHeight: 220)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .accessibilityLabel("PEM private key")
                        } footer: { Text("密钥仅保存到系统 Keychain。留空保留已有凭据。") }.mudiRow()
                    }.mudiGroupedList().navigationTitle("私钥").navigationBarTitleDisplayMode(.inline)
                } label: { credentialRow("私钥", value: pemPrivateKey.isEmpty ? "未设置" : "OpenSSH · Keychain") }
                NavigationLink {
                    Form {
                        Section {
                            SecureField("密码", text: $password)
                                .textContentType(.password).textInputAutocapitalization(.never).autocorrectionDisabled()
                        } footer: { Text("密码仅保存到系统 Keychain。留空保留已有凭据。") }.mudiRow()
                    }.mudiGroupedList().navigationTitle("密码").navigationBarTitleDisplayMode(.inline)
                } label: { credentialRow("密码", value: password.isEmpty ? "未设置" : "已保存在 Keychain") }
            } header: { MudiSectionHeader(title: "凭据") }.mudiRow()

            if parsedPort == nil { validation("端口范围为 1–65535。") }
            if parsedAddresses == nil { validation("至少填写一个不重复的有效地址。") }
            if let validationMessage { validation(validationMessage) }
        }
        .mudiGroupedList()
        .navigationTitle(host == nil ? "添加主机" : "编辑主机")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消", action: onCancel).buttonStyle(MudiPillStyle()).foregroundStyle(MudiPalette.body) }.mudiToolbarBackground()
            ToolbarItem(placement: .confirmationAction) {
                Button("保存", action: save).buttonStyle(MudiPillStyle(filled: true))
                    .disabled(!canSave).accessibilityIdentifier("save-host-button")
            }.mudiToolbarBackground()
        }
        .sheet(isPresented: Binding(get: { editingAddressID != nil }, set: { if !$0 { editingAddressID = nil } })) {
            if let index = addressDrafts.firstIndex(where: { $0.id == editingAddressID }) {
                NavigationStack {
                    Form {
                        Section {
                            field("名称", text: $addressDrafts[index].label)
                            field("地址", text: $addressDrafts[index].address, mono: true)
                                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                            field("端口", text: $addressDrafts[index].portOverride, mono: true)
                                .keyboardType(.numberPad)
                        } footer: { Text("端口留空使用主机端口 \(port)。") }.mudiRow()
                    }
                    .mudiGroupedList().navigationTitle("编辑地址").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { editingAddressID = nil } } }
                }
            }
        }
    }

    private func field(_ title: String, text: Binding<String>, mono: Bool = false) -> some View {
        HStack(spacing: 12) {
            Text(title).font(MudiTypography.body()).foregroundStyle(MudiPalette.body).frame(width: 76, alignment: .leading)
            TextField(title, text: text).font(mono ? MudiTypography.mono(15) : MudiTypography.body())
        }.frame(minHeight: 44)
    }
    private func credentialRow(_ title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Text(title).foregroundStyle(MudiPalette.body).frame(width: 76, alignment: .leading)
            Text(value).font(MudiTypography.mono(15)).foregroundStyle(MudiPalette.mute)
        }.frame(minHeight: 44)
    }
    private func validation(_ message: String) -> some View {
        Text(message).font(MudiTypography.body(12)).foregroundStyle(MudiPalette.red).listRowBackground(Color.clear)
    }
    private func moveAddress(_ id: UUID, by delta: Int) {
        guard let source = addressDrafts.firstIndex(where: { $0.id == id }),
              addressDrafts.indices.contains(source + delta) else { return }
        addressDrafts.swapAt(source, source + delta)
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
            "Auto"
        case .mosh:
            "Mosh"
        case .ssh:
            "SSH"
        }
    }
}
