import Foundation
import SwiftUI

struct QuickModel: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var command: String
    /// Empty means all agents, including unknown agents.
    var scopes: [String] = []
    func applies(to agent: String?) -> Bool { scopes.isEmpty || scopes.contains(agent ?? "") }
}

@MainActor
final class QuickModelStore: ObservableObject {
    static let shared = QuickModelStore()
    @Published var models: [QuickModel] { didSet { persist() } }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "quick-models-v1"), let decoded = try? JSONDecoder().decode([QuickModel].self, from: data) {
            models = decoded
        } else {
            models = [ (1, "pi"), (2, "claude code") ].flatMap { key, scope in
                (defaults.stringArray(forKey: "agent-models-\(key)") ?? []).map {
                    QuickModel(name: $0, command: "/model " + $0, scopes: [scope])
                }
            }
            persist()
        }
    }
    private let defaults: UserDefaults
    private func persist() { if let data = try? JSONEncoder().encode(models) { defaults.set(data, forKey: "quick-models-v1") } }
}

struct QuickModelSettingsView: View {
    @ObservedObject var store = QuickModelStore.shared
    @State private var editing: QuickModel?
    @State private var deleted: (Int, QuickModel)?
    var body: some View {
        List {
            Section(MudiL10n.format("列表 · %@ 项", String(store.models.count))) {
                ForEach(store.models) { model in
                    Button { editing = model } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack { Text(model.name); Spacer(); Text(model.scopes.isEmpty ? MudiL10n.text("全部") : model.scopes.map(scopeTitle).joined(separator: " / ")).font(.caption).foregroundStyle(.secondary) }
                            Text(model.command).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                        }.foregroundStyle(.primary)
                    }
                }.onMove { store.models.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { offsets in
                    if let index = offsets.first { deleted = (index, store.models[index]) }
                    store.models.remove(atOffsets: offsets)
                }
            }
            if let deleted {
                Button(MudiL10n.text("撤销删除")) { store.models.insert(deleted.1, at: min(deleted.0, store.models.count)); self.deleted = nil }
            }
            Section(MudiL10n.text("发送")) { Text(MudiL10n.text("选中后发送原样命令和回车到当前 pane。这里只记录 Mudi 的上次发送，不读取 agent 当前模型。")).font(.footnote).foregroundStyle(.secondary) }
        }
        .navigationTitle(MudiL10n.text("快捷模型")).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button(MudiL10n.text("＋ 添加")) { editing = QuickModel(name: "", command: "") } }
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
        }
        .sheet(item: $editing) { model in NavigationStack { QuickModelEditView(model: model, store: store) } }
    }
}

private func scopeTitle(_ value: String) -> String { ["pi": "Pi", "claude code": "Claude Code", "codex": "Codex"][value] ?? value }

struct QuickModelEditView: View {
    @State var model: QuickModel
    @ObservedObject var store: QuickModelStore
    @Environment(\.dismiss) private var dismiss
    var valid: Bool { !model.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.command.contains("\n") && !model.command.contains("\r") }
    var body: some View {
        Form {
            Section(MudiL10n.text("显示名称 · 弹层中显示")) { TextField(MudiL10n.text("例如 Opus 4.1"), text: $model.name) }
            Section(MudiL10n.text("命令 · 必填，原样发送")) {
                TextField("/model …", text: $model.command).font(.system(.body, design: .monospaced)).autocorrectionDisabled().textInputAutocapitalization(.never)
                if !valid { Text(MudiL10n.text("命令不能为空，且只能是一行。例：/model anthropic/claude-opus-4-1")).font(.caption).foregroundStyle(.red) }
            }
            Section(MudiL10n.text("适用范围 · 可多选")) {
                Toggle(MudiL10n.text("全部"), isOn: Binding(get: { model.scopes.isEmpty }, set: { if $0 { model.scopes = [] } else { model.scopes = ["pi"] } }))
                ForEach(["pi", "claude code", "codex"], id: \.self) { scope in
                    Toggle(scopeTitle(scope), isOn: Binding(get: { model.scopes.contains(scope) }, set: { enabled in
                        if enabled { if !model.scopes.contains(scope) { model.scopes.append(scope) } } else { model.scopes.removeAll { $0 == scope } }
                    }))
                }
                Text(MudiL10n.text("选「全部」时任何 agent 都显示；否则只在对应 agent 的 pane 中显示。")).font(.caption)
            }
            Section(MudiL10n.text("预览")) { Text(model.command.isEmpty ? MudiL10n.text("（命令为空，无法发送）") : model.command).font(.system(.caption, design: .monospaced)) }
            if store.models.contains(where: { $0.id == model.id }) { Button(MudiL10n.text("删除此模型"), role: .destructive) { store.models.removeAll { $0.id == model.id }; dismiss() } }
        }
        .navigationTitle(MudiL10n.text("编辑模型")).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(MudiL10n.text("取消")) { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button(MudiL10n.text("保存")) {
                if model.name.trimmingCharacters(in: .whitespaces).isEmpty { model.name = model.command }
                if let index = store.models.firstIndex(where: { $0.id == model.id }) { store.models[index] = model } else { store.models.append(model) }
                dismiss()
            }.disabled(!valid) }
        }
    }
}
