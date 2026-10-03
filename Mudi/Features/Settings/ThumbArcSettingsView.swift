import SwiftUI
import UIKit

struct ThumbArcSettingsView: View {
    @ObservedObject var model: RootViewModel
    @State private var draft: ThumbArcPreferences
    @State private var practicePresented = false
    @Environment(\.dismiss) private var dismiss
    init(model: RootViewModel) {
        self.model = model
        _draft = State(initialValue: model.preferences.thumbArc)
    }
    var body: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    ThumbArcDemo(preferences: draft, interactive: false).frame(height: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    Text("双击终端后不松手拖动呼出 · 松开执行 · 回起点取消")
                        .font(MudiTypography.body(12)).foregroundStyle(MudiPalette.mute)
                }.padding(.vertical, 16)
            } header: {
                HStack { Text("预览"); Spacer(); Text(draft.isLeftHanded ? "左手 · 向右上展开" : "右手 · 向左上展开") }
                    .font(MudiTypography.body(13)).foregroundStyle(MudiPalette.mute).textCase(nil)
            } footer: {
                Text("单指长按仍用于 SwiftTerm 选择文本，不会触发快捷弧。")
                    .font(MudiTypography.body(12)).foregroundStyle(MudiPalette.mute)
            }.mudiRow()
            Section {
                ForEach(draft.actions, id: \.self) { action in actionRow(action) }
                    .onDelete { draft.actions.remove(atOffsets: $0) }
                    .onMove { draft.actions.move(fromOffsets: $0, toOffset: $1) }
            } header: { MudiSectionHeader(title: "槽位", count: draft.actions.count) } footer: {
                Text("按住 ≡ 拖动排序 · 顺序即弧上由下到上")
                    .font(MudiTypography.body(12)).foregroundStyle(MudiPalette.mute)
            }
            .mudiRow()
            Section {
                ForEach(ThumbArcAction.allCases.filter { !draft.actions.contains($0) }, id: \.self) { action in
                    Button { draft.actions.append(action) } label: {
                        HStack(spacing: 12) {
                            actionRow(action)
                            Spacer()
                            Image(systemName: "plus.circle.fill").foregroundStyle(draft.actions.count >= 6 ? MudiPalette.dim : MudiPalette.ink)
                        }
                    }.buttonStyle(.plain).disabled(draft.actions.count >= 6)
                }
                if draft.actions.contains(.customText) {
                    TextField("自定义片段", text: $draft.customText, axis: .vertical)
                        .lineLimit(3...6).font(MudiTypography.mono(13)).autocorrectionDisabled()
                        .accessibilityIdentifier("thumb-arc-custom-text")
                }
            } header: { MudiSectionHeader(title: "可用操作") } footer: {
                Text("移除一个槽位后即可添加。最多 6 个，保持拇指一次滑动可达。")
                    .font(MudiTypography.body(12)).foregroundStyle(MudiPalette.mute)
            }.mudiRow()
            Section {
                Toggle(isOn: $draft.isLeftHanded) {
                    option("左手模式", detail: "镜像布局，弧向右上展开")
                }.accessibilityIdentifier("thumb-arc-left-hand")
                Toggle(isOn: $draft.hapticsEnabled) {
                    option("触感反馈", detail: "滑过按钮时轻触提示")
                }.accessibilityIdentifier("thumb-arc-haptics")
                Button { practicePresented = true } label: {
                    HStack { option("练习模式", detail: "跟随引导练习拖选，不会发送按键"); Spacer(); MudiIcon.chevronRight.image }
                }.buttonStyle(.plain).accessibilityIdentifier("thumb-arc-practice-button")
            } header: { MudiSectionHeader(title: "手势") }.mudiRow()
            Section {
                Button("恢复默认", role: .destructive) { draft = ThumbArcPreferences() }
                    .frame(maxWidth: .infinity).foregroundStyle(MudiPalette.red)
            }.mudiRow()
        }
        .mudiGroupedList()
        .environment(\.editMode, .constant(.active))
        .navigationTitle("拇指快捷弧").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.buttonStyle(MudiPillStyle(filled: true)) }.mudiToolbarBackground() }
        .onChange(of: draft) { _, value in model.updateThumbArc(value) }
        .sheet(isPresented: $practicePresented) {
            NavigationStack {
                VStack(spacing: 16) {
                    Text("双击后保持按住，拖到按钮再松开。回到起点可取消。")
                        .font(MudiTypography.body(14)).foregroundStyle(MudiPalette.mute).padding(.horizontal, 20)
                    ThumbArcDemo(preferences: draft, interactive: true)
                        .accessibilityIdentifier("thumb-arc-practice")
                }
                .background(MudiPalette.canvas).navigationTitle("练习模式").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { practicePresented = false } } }
            }
        }
    }
    private func option(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(MudiTypography.body())
            Text(detail).font(MudiTypography.body(12)).foregroundStyle(MudiPalette.mute)
        }.padding(.vertical, 6)
    }
    private func actionRow(_ action: ThumbArcAction) -> some View {
        HStack(spacing: 12) {
            Group {
                if let icon = action.icon { icon.image }
                else { Text(action.glyph).font(MudiTypography.body(action.glyph.count > 3 ? 10 : 12, weight: .medium)) }
            }
            .foregroundStyle(MudiPalette.ink).frame(width: 32, height: 32)
            .background(MudiPalette.surface, in: Circle())
            .overlay(Circle().stroke(MudiPalette.border, lineWidth: 1))
            Text(action.title).font(MudiTypography.body(15))
            Text(action.detail).font(MudiTypography.body(12)).foregroundStyle(MudiPalette.mute).lineLimit(1)
        }.frame(minHeight: 54)
    }
}

private struct ThumbArcDemo: UIViewRepresentable {
    let preferences: ThumbArcPreferences
    let interactive: Bool
    func makeUIView(context: Context) -> ThumbArcDemoSurface { ThumbArcDemoSurface(interactive: interactive) }
    func updateUIView(_ view: ThumbArcDemoSurface, context: Context) { view.preferences = preferences; view.setNeedsLayout() }
}

@MainActor
private final class ThumbArcDemoSurface: UIView {
    var preferences = ThumbArcPreferences()
    private let interactive: Bool
    private let overlay = MudiThumbArcOverlay()
    private let label = UILabel()
    init(interactive: Bool) {
        self.interactive = interactive
        super.init(frame: .zero)
        backgroundColor = MudiPalette.canvasUI
        label.text = "~/dev/herdr (main) $ ▌"
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.textColor = MudiPalette.inkUI
        addSubview(label)
        if interactive {
            let gesture = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
            gesture.numberOfTapsRequired = 1; gesture.minimumPressDuration = 0.08
            addGestureRecognizer(gesture)
        } else { addSubview(overlay) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = CGRect(x: 12, y: 12, width: bounds.width - 24, height: 20)
        if !interactive {
            overlay.frame = bounds
            overlay.begin(origin: CGPoint(x: bounds.width * 0.8, y: bounds.height * 0.74), preferences: preferences)
        }
    }
    @objc private func pressed(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            overlay.frame = bounds; addSubview(overlay)
            overlay.begin(origin: gesture.location(in: self), preferences: preferences)
        case .changed: overlay.select(at: gesture.location(in: self))
        case .ended:
            overlay.select(at: gesture.location(in: self))
            label.text = overlay.finish().map { "\($0.title) · 已练习，不发送按键" } ?? "已取消 · 回起点取消"
        case .cancelled, .failed: overlay.cancel()
        default: break
        }
    }
}
