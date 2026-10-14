import UIKit
import SwiftUI

/// A scrollable popup, kept separate from the existing terminal key row.
/// Inline confirmation doesn't steal keyboard focus or send before consent.
@MainActor
final class MudiAgentActionsPanel: UIView {
    var onAction: ((String) -> Void)?
    var onPreset: ((TerminalAgentPreset) -> Void)?
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?
    var onClose: (() -> Void)?
    var onKeyboard: (() -> Void)?
    var onThinking: ((String) -> Void)?
    private let thinking = UISegmentedControl(items: ["off", "low", "medium", "high"])
    private let thinkingRow = UIStackView()

    private let presetLabel = UILabel()
    private let presetPicker = UISegmentedControl(items: TerminalAgentPreset.allCases.map(\.title))
    private let hintLabel = UILabel()
    private let actionsStack = UIStackView()
    private let configureModelsButton = UIButton(type: .system)
    private var currentState = TerminalAgentActionsState()
    private let operations = UIStackView()
    private let confirmation = UIStackView()
    private let commandLabel = UILabel()
    private let warningLabel = UILabel()
    private let confirmButton = UIButton(type: .system)
    private var renderedPreset: TerminalAgentPreset?
    private var panelHeight: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        accessibilityIdentifier = "terminal-agent-actions-panel"
        isHidden = true
        backgroundColor = .clear
        let backdrop = MudiTerminalShortcutBar.makeMaterialView()
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.isUserInteractionEnabled = false
        backdrop.layer.cornerRadius = 20
        backdrop.clipsToBounds = true
        addSubview(backdrop)
        NSLayoutConstraint.activate([backdrop.leadingAnchor.constraint(equalTo: leadingAnchor), backdrop.trailingAnchor.constraint(equalTo: trailingAnchor), backdrop.topAnchor.constraint(equalTo: topAnchor), backdrop.bottomAnchor.constraint(equalTo: bottomAnchor)])
        layer.cornerRadius = 20
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 2)

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let content = UIStackView()
        content.axis = .vertical
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        scroll.addSubview(content)
        panelHeight = heightAnchor.constraint(equalToConstant: 340)
        NSLayoutConstraint.activate([
            panelHeight,
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
        ])

        let heading = UIStackView()
        heading.axis = .horizontal
        heading.alignment = .center
        let headingText = UIStackView()
        headingText.axis = .vertical
        headingText.spacing = 3
        let title = makeLabel("π  Agent", size: 16, weight: .semibold)
        headingText.addArrangedSubview(title)
        presetLabel.font = MudiTypography.uiFont(12)
        presetLabel.textColor = MudiPalette.muteUI
        presetLabel.accessibilityIdentifier = "terminal-agent-preset-label"
        headingText.addArrangedSubview(presetLabel)
        heading.addArrangedSubview(headingText)
        let keyboard = UIButton(type: .system)
        keyboard.setTitle(MudiL10n.text("⌨ 键盘"), for: .normal)
        keyboard.setTitleColor(MudiPalette.inkUI, for: .normal)
        keyboard.accessibilityIdentifier = "terminal-agent-panel-keyboard"
        keyboard.addAction(UIAction { [weak self] _ in self?.onKeyboard?() }, for: .touchUpInside)
        keyboard.titleLabel?.font = MudiTypography.uiFont(12)
        keyboard.widthAnchor.constraint(equalToConstant: 90).isActive = true
        keyboard.heightAnchor.constraint(equalToConstant: 44).isActive = true
        heading.addArrangedSubview(keyboard)
        let close = UIButton(type: .system)
        close.setImage(MudiIcon.close.uiImage, for: .normal)
        close.tintColor = MudiPalette.inkUI
        close.accessibilityIdentifier = "terminal-agent-actions-close"
        close.accessibilityLabel = MudiL10n.text("关闭 Agent Actions")
        close.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)
        close.widthAnchor.constraint(equalToConstant: 44).isActive = true
        close.heightAnchor.constraint(equalToConstant: 44).isActive = true
        heading.addArrangedSubview(close)
        content.addArrangedSubview(heading)

        operations.axis = .vertical
        operations.spacing = 10
        presetPicker.accessibilityIdentifier = "terminal-agent-preset-picker"
        presetPicker.accessibilityLabel = MudiL10n.text("内置操作预设")
        presetPicker.heightAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true
        presetPicker.addTarget(self, action: #selector(presetChanged), for: .valueChanged)
        presetPicker.heightAnchor.constraint(equalToConstant: 30).isActive = true
        operations.addArrangedSubview(presetPicker)
        hintLabel.font = MudiTypography.uiFont(11)
        hintLabel.textColor = MudiPalette.muteUI
        hintLabel.numberOfLines = 0
        hintLabel.isHidden = true
        configureModelsButton.setTitle(MudiL10n.text("模型  ·  选择快捷模型  ⌄"), for: .normal)
        configureModelsButton.contentHorizontalAlignment = .left
        configureModelsButton.backgroundColor = MudiPalette.keyUI.withAlphaComponent(0.45)
        configureModelsButton.layer.cornerRadius = 10
        configureModelsButton.heightAnchor.constraint(equalToConstant: 40).isActive = true
        configureModelsButton.accessibilityIdentifier = "terminal-agent-model-configure"
        configureModelsButton.addAction(UIAction { [weak self] _ in self?.openModels() }, for: .touchUpInside)
        operations.addArrangedSubview(configureModelsButton)
        thinkingRow.axis = .horizontal
        thinkingRow.spacing = 10
        thinkingRow.addArrangedSubview(makeLabel("Thinking", size: 12))
        thinking.accessibilityIdentifier = "terminal-agent-thinking"
        thinking.selectedSegmentIndex = UISegmentedControl.noSegment
        thinking.addTarget(self, action: #selector(thinkingChanged), for: .valueChanged)
        thinkingRow.addArrangedSubview(thinking)
        operations.addArrangedSubview(thinkingRow)
        actionsStack.axis = .vertical
        actionsStack.spacing = 6
        operations.addArrangedSubview(actionsStack)
        content.addArrangedSubview(operations)
        setupConfirmation()
        content.addArrangedSubview(confirmation)
        render(TerminalAgentActionsState())
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func render(_ state: TerminalAgentActionsState) {
        currentState = state
        configureModelsButton.isHidden = false
        thinkingRow.isHidden = state.preset != .pi
        if state.pendingCommand == nil { thinking.selectedSegmentIndex = UISegmentedControl.noSegment }
        presetLabel.text = MudiL10n.text("当前预设：") + state.preset.title
        presetPicker.selectedSegmentIndex = state.preset.rawValue
        switch state.preset {
        case .pi:
            hintLabel.text = MudiL10n.text("Pi 命令快捷操作；Ctrl+ 与 Shift+Tab 使用通用快捷栏。命令发送前会确认。")
        case .claudeCode:
            hintLabel.text = MudiL10n.text("Claude Code 的 Ctrl+ 与 Shift+Tab 已由通用快捷栏提供。命令发送前会确认。")
        case .generic:
            hintLabel.text = MudiL10n.text("通用终端按键；也可手动选择 Pi 或 Claude Code 预设。")
        }
        if renderedPreset != state.preset {
            renderedPreset = state.preset
            for view in actionsStack.arrangedSubviews {
                actionsStack.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            let actions = state.preset.actions.filter { !$0.id.hasPrefix("configured-model-") }
            for start in stride(from: 0, to: actions.count, by: 3) {
                let row = UIStackView()
                row.axis = .horizontal
                row.spacing = 8
                row.distribution = .fillEqually
                for action in actions[start..<min(start + 3, actions.count)] { row.addArrangedSubview(makeActionButton(action)) }
                while row.arrangedSubviews.count < 3 { row.addArrangedSubview(UIView()) }
                actionsStack.addArrangedSubview(row)
            }
        }
        commandLabel.text = state.pendingCommand
        let destructive = state.pendingCommand == "/rewind" || state.pendingCommand == "/clear"
        configureModelsButton.setTitle(MudiL10n.text("模型  ·  ") + (lastSentModel.map { $0.replacingOccurrences(of: "/model ", with: "") } ?? MudiL10n.text("选择快捷模型")) + "  ⌄", for: .normal)
        warningLabel.text = destructive
            ? MudiL10n.text("将追加到远端当前输入并发送 Enter。/rewind 会回滚代码和/或对话；/clear 会结束当前上下文并开启新会话。请确认编辑器为空。")
            : MudiL10n.text("将追加到远端当前输入并发送 Enter。不会清空已有内容，请先确认编辑器为空且没有未完成输入。")
        confirmation.isHidden = state.pendingCommand == nil
        operations.isHidden = state.pendingCommand != nil
        confirmButton.isEnabled = state.pendingCommand != nil
    }

    func setAvailableHeight(_ height: CGFloat) {
        let resolved = max(0, min(500, height))
        guard abs(panelHeight.constant - resolved) > 0.5 else { return }
        panelHeight.constant = resolved
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowOpacity = MudiPalette.glassShadowOpacity(in: traitCollection)
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: 16).cgPath
    }

    var onModel: ((QuickModel) -> Void)?
    private var sentModels: [String: String] = [:]
    var lastSentModel: String? {
        get { sentModels[modelScopeKey] }
        set { sentModels[modelScopeKey] = newValue }
    }
    private var modelScopeKey: String {
        guard let context = currentState.context else { sentModels.removeAll(); return "unattached" }
        return "\(context.hostID)|\(String(describing: context.sessionID))|\(String(describing: context.paneID))"
    }
    private func openModels() {
        var responder: UIResponder? = self
        while let current = responder, !(current is UIViewController) { responder = current.next }
        guard let presenter = responder as? UIViewController else { return }
        let state = currentState
        let page = QuickModelPickerController(agent: state.context?.normalizedAgentName, lastSent: lastSentModel)
        page.onSelect = { [weak self] model in
            guard let self, self.currentState.context == state.context else { return }
            self.onModel?(model)
        }
        page.modalPresentationStyle = .popover
        page.preferredContentSize = CGSize(width: 340, height: 300)
        page.popoverPresentationController?.delegate = page
        page.popoverPresentationController?.sourceView = configureModelsButton
        page.popoverPresentationController?.sourceRect = configureModelsButton.bounds
        page.popoverPresentationController?.permittedArrowDirections = .down
        presenter.present(page, animated: true)
    }

    @objc private func thinkingChanged() {
        let levels = ["off", "low", "medium", "high"]
        guard levels.indices.contains(thinking.selectedSegmentIndex) else { return }
        onThinking?(levels[thinking.selectedSegmentIndex])
    }

    @objc private func presetChanged() {
        guard let preset = TerminalAgentPreset(rawValue: presetPicker.selectedSegmentIndex) else { return }
        onPreset?(preset)
    }

    private func makeActionButton(_ action: TerminalAgentAction) -> UIButton {
        let button = UIButton(type: .system)
        var config = UIButton.Configuration.plain()
        config.title = action.keyLabel
        config.subtitle = action.title
        config.titleAlignment = .leading
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var result = attributes
            result.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .medium)
            return result
        }
        config.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var result = attributes
            result.font = MudiTypography.uiFont(10)
            result.foregroundColor = MudiPalette.muteUI
            return result
        }
        config.titleLineBreakMode = .byTruncatingTail
        config.subtitleLineBreakMode = .byTruncatingTail
        config.baseForegroundColor = MudiPalette.inkUI
        config.background.backgroundColor = MudiPalette.keyUI.withAlphaComponent(0.65)
        config.background.cornerRadius = 9
        button.configuration = config
        button.contentHorizontalAlignment = .leading
        button.heightAnchor.constraint(equalToConstant: 50).isActive = true
        button.accessibilityIdentifier = "terminal-agent-action-" + action.id
        button.accessibilityLabel = action.title + " · " + action.keyLabel
        button.addAction(UIAction { [weak self] _ in self?.onAction?(action.id) }, for: .touchUpInside)
        return button
    }

    private func setupConfirmation() {
        confirmation.axis = .vertical
        confirmation.spacing = 12
        confirmation.accessibilityIdentifier = "terminal-agent-command-confirmation"
        confirmation.addArrangedSubview(makeLabel(MudiL10n.text("确认发送命令？"), size: 16, weight: .semibold))
        commandLabel.font = UIFont.monospacedSystemFont(ofSize: 17, weight: .medium)
        commandLabel.textColor = MudiPalette.inkUI
        commandLabel.numberOfLines = 0
        commandLabel.accessibilityIdentifier = "terminal-agent-command-text"
        confirmation.addArrangedSubview(commandLabel)
        warningLabel.font = MudiTypography.uiFont(12)
        warningLabel.textColor = MudiPalette.muteUI
        warningLabel.numberOfLines = 0
        warningLabel.accessibilityIdentifier = "terminal-agent-command-warning"
        confirmation.addArrangedSubview(warningLabel)
        let buttons = UIStackView()
        buttons.axis = .horizontal
        buttons.distribution = .fillEqually
        buttons.spacing = 8
        let cancel = UIButton(type: .system)
        cancel.setTitle(MudiL10n.text("取消"), for: .normal)
        cancel.accessibilityIdentifier = "terminal-agent-command-cancel"
        cancel.addAction(UIAction { [weak self] _ in self?.onCancel?() }, for: .touchUpInside)
        confirmButton.setTitle(MudiL10n.text("发送 + Enter"), for: .normal)
        confirmButton.accessibilityIdentifier = "terminal-agent-command-confirm"
        confirmButton.addAction(UIAction { [weak self] _ in self?.onConfirm?() }, for: .touchUpInside)
        for button in [cancel, confirmButton] {
            button.tintColor = MudiPalette.inkUI
            button.backgroundColor = MudiPalette.keyUI
            button.layer.cornerRadius = 9
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            buttons.addArrangedSubview(button)
        }
        confirmation.addArrangedSubview(buttons)
    }

    private func makeLabel(_ text: String, size: CGFloat, weight: UIFont.Weight = .regular) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = MudiTypography.uiFont(size, weight: weight)
        label.textColor = MudiPalette.inkUI
        label.numberOfLines = 0
        return label
    }
}

@MainActor
final class AgentModelListController: UITableViewController {
    let preset: TerminalAgentPreset
    var onSelect: ((String) -> Void)?
    init(preset: TerminalAgentPreset) {
        self.preset = preset
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = preset.title + MudiL10n.text(" 模型")
        tableView.accessibilityIdentifier = "terminal-agent-model-list"
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: MudiL10n.text("关闭"), style: .plain, target: self, action: #selector(close))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: MudiL10n.text("配置"), style: .plain, target: self, action: #selector(configure))
    }
    @objc private func close() { dismiss(animated: true) }
    @objc private func configure() {
        let editor = AgentModelEditorController(preset: preset)
        editor.onSave = { [weak self] in self?.tableView.reloadData() }
        navigationController?.pushViewController(editor, animated: true)
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { max(1, preset.configuredModels.count) }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        let models = preset.configuredModels
        cell.textLabel?.text = models.isEmpty ? MudiL10n.text("尚未配置模型，点右上角配置") : models[indexPath.row]
        cell.textLabel?.numberOfLines = 0
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let models = preset.configuredModels
        guard models.indices.contains(indexPath.row) else { return }
        dismiss(animated: true) { [weak self] in self?.onSelect?(models[indexPath.row]) }
    }
}

@MainActor
final class AgentModelEditorController: UIViewController {
    let preset: TerminalAgentPreset
    let input = UITextView()
    var onSave: (() -> Void)?
    init(preset: TerminalAgentPreset) { self.preset = preset; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = MudiL10n.text("配置模型（每行一个 ID）")
        view.backgroundColor = .systemBackground
        input.text = preset.configuredModels.joined(separator: "\n")
        input.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        input.autocorrectionType = .no
        input.autocapitalizationType = .none
        input.accessibilityIdentifier = "terminal-agent-model-input"
        input.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(input)
        NSLayoutConstraint.activate([
            input.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            input.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            input.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            input.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        ])
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: MudiL10n.text("保存"), style: .done, target: self, action: #selector(save))
    }
    @objc func save() {
        preset.saveModels(input.text)
        onSave?()
        navigationController?.popViewController(animated: true)
    }
}

@MainActor
final class QuickModelPickerController: UITableViewController, UIPopoverPresentationControllerDelegate {
    func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle { .none }
    let agent: String?
    let lastSent: String?
    var onSelect: ((QuickModel) -> Void)?
    var models: [QuickModel] { QuickModelStore.shared.models.filter { $0.applies(to: agent) } }
    init(agent: String?, lastSent: String?) { self.agent = agent; self.lastSent = lastSent; super.init(style: .plain) }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = .clear
        tableView.backgroundView = MudiTerminalShortcutBar.makeMaterialView()
        tableView.accessibilityIdentifier = "quick-model-picker"
        tableView.rowHeight = 58
    }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); tableView.reloadData() }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { max(1, models.count) }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.backgroundColor = .clear
        if models.isEmpty { cell.textLabel?.text = MudiL10n.text("还没有快捷模型"); cell.detailTextLabel?.text = MudiL10n.text("去设置添加 →") }
        else {
            let model = models[indexPath.row]
            cell.textLabel?.text = model.name + "  · " + (model.scopes.isEmpty ? MudiL10n.text("全部") : model.scopes.map { ["pi": "Pi", "claude code": "Claude Code", "codex": "Codex"][$0] ?? $0 }.joined(separator: "/"))
            cell.detailTextLabel?.text = model.command
            cell.detailTextLabel?.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            cell.accessoryType = lastSent == model.command ? .checkmark : .none
            if lastSent == model.command { cell.detailTextLabel?.text = model.command + MudiL10n.text(" · 上次发送") }
        }
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if models.isEmpty { present(UINavigationController(rootViewController: UIHostingController(rootView: QuickModelSettingsView())), animated: true); return }
        let model = models[indexPath.row]
        dismiss(animated: true) { [weak self] in self?.onSelect?(model) }
    }
}
