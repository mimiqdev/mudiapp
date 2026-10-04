import UIKit

private struct ComposerRecord: Codable {
    var text: String
    var target: String
    var date: Date
    var kind: String
}

/// Native text input stays in the keyboard slot instead of presenting another controller.
@MainActor
final class MudiComposerCard: UIView, UITextViewDelegate {
    weak var bar: MudiTerminalShortcutBar?
    let input = UITextView()
    let toolbarScroll = MudiKeyScrollView()
    let sendButton = MudiKeyButton(type: .custom)
    private let targetLabel = UILabel()
    private let placeholder = UILabel()
    private let tools = UIStackView()
    private let pinned = UIStackView()
    private var inputHeight: NSLayoutConstraint!
    private var confirmedText: String?
    private var bracketedPaste = true
    private var appendReturn = true
    private var target = "Terminal"
    private var wasEmpty = true
    private var records: [ComposerRecord] {
        get { (try? JSONDecoder().decode([ComposerRecord].self, from: UserDefaults.standard.data(forKey: "dev.mudi.mobile.composer-records") ?? Data())) ?? [] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(Array(newValue.prefix(60))), forKey: "dev.mudi.mobile.composer-records") }
    }
    private var menuButtons: [String: UIButton] = [:]
    private(set) var preferredHeight: CGFloat = 80

    init(bar: MudiTerminalShortcutBar) {
        self.bar = bar
        super.init(frame: .zero)
        accessibilityIdentifier = "terminal-compose-card"
        layer.cornerRadius = 20; layer.borderWidth = 1
        input.delegate = self
        input.backgroundColor = .clear
        input.textContainerInset = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        input.textContainer.lineFragmentPadding = 0
        input.adjustsFontForContentSizeCategory = true
        input.accessibilityIdentifier = "terminal-compose-input"
        input.accessibilityLabel = "发送到终端的内容"
        input.smartQuotesType = .no; input.smartDashesType = .no
        placeholder.text = "输入要发送到终端的内容…"
        placeholder.isUserInteractionEnabled = false
        targetLabel.textAlignment = .right; targetLabel.numberOfLines = 0
        targetLabel.adjustsFontForContentSizeCategory = true
        tools.axis = .horizontal; tools.spacing = 0; tools.alignment = .center
        pinned.axis = .horizontal; pinned.spacing = 0; pinned.alignment = .center
        toolbarScroll.accessibilityIdentifier = "terminal-compose-scroll"
        for view in [targetLabel, input, toolbarScroll, pinned] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        input.addSubview(placeholder)
        tools.translatesAutoresizingMaskIntoConstraints = false
        toolbarScroll.addSubview(tools)
        inputHeight = input.heightAnchor.constraint(equalToConstant: 30)
        NSLayoutConstraint.activate([
            targetLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            targetLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            targetLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            input.topAnchor.constraint(equalTo: targetLabel.bottomAnchor, constant: 2),
            input.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            input.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16), inputHeight,
            placeholder.leadingAnchor.constraint(equalTo: input.leadingAnchor),
            placeholder.topAnchor.constraint(equalTo: input.topAnchor, constant: 4),
            placeholder.widthAnchor.constraint(lessThanOrEqualTo: input.widthAnchor),
            toolbarScroll.topAnchor.constraint(equalTo: input.bottomAnchor, constant: 2),
            toolbarScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            toolbarScroll.trailingAnchor.constraint(equalTo: pinned.leadingAnchor),
            toolbarScroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            toolbarScroll.heightAnchor.constraint(equalToConstant: 44),
            tools.leadingAnchor.constraint(equalTo: toolbarScroll.contentLayoutGuide.leadingAnchor),
            tools.trailingAnchor.constraint(equalTo: toolbarScroll.contentLayoutGuide.trailingAnchor),
            tools.topAnchor.constraint(equalTo: toolbarScroll.contentLayoutGuide.topAnchor),
            tools.bottomAnchor.constraint(equalTo: toolbarScroll.contentLayoutGuide.bottomAnchor),
            tools.heightAnchor.constraint(equalTo: toolbarScroll.frameLayoutGuide.heightAnchor),
            pinned.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            pinned.centerYAnchor.constraint(equalTo: toolbarScroll.centerYAnchor)
        ])
        addTool(.composeClose, "关闭", id: "close") { [weak bar] _ in bar?.closeCompose() }
        addTool(nil, "Escape", id: "escape", title: "Esc") { [weak bar] _ in bar?.sendEscape() }
        addTool(.composeMove, "方向键", id: "dpad") { [weak bar] button in
            bar?.dpadAnchorView = button; bar?.toggleDPad()
        }
        menuButtons["history"] = addTool(.composeHistory, "历史 / 草稿", id: "history")
        addTool(.composeLayers, "选择 Pane", id: "picker") { [weak bar] _ in bar?.closeCompose(); bar?.jumpToPanes() }
        menuButtons["insert"] = addTool(.composePlus, "插入", id: "insert")
        menuButtons["snippet"] = addTool(.composeStar, "片段", id: "snippet")
        menuButtons["target"] = addTool(.composeTarget, "发送目标", id: "target")
        addTool(.composeClear, "清空", id: "clear") { [weak self] _ in self?.setText("") }
        let mic = makeButton(.composeMic, "系统键盘听写", id: "dictation")
        mic.accessibilityHint = "在系统键盘上使用麦克风听写"
        mic.addAction(UIAction { [weak self] _ in self?.input.becomeFirstResponder() }, for: .touchUpInside)
        pinned.addArrangedSubview(mic)
        sendButton.setImage(MudiIcon.composeSend.uiImage, for: .normal)
        sendButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        sendButton.accessibilityIdentifier = "terminal-compose-send"
        sendButton.accessibilityLabel = "发送"
        sendButton.addAction(UIAction { [weak self] _ in self?.send() }, for: .touchUpInside)
        pinned.addArrangedSubview(sendButton)
        updateStyle(); updateMenus(); textViewDidChange(input)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func makeButton(_ icon: MudiIcon?, _ label: String, id: String, title: String? = nil) -> MudiKeyButton {
        let button = MudiKeyButton(type: .custom)
        button.setImage(icon?.uiImage, for: .normal); button.setTitle(title, for: .normal)
        button.titleLabel?.font = MudiTypography.uiFont(13)
        button.accessibilityLabel = label; button.accessibilityIdentifier = "terminal-compose-" + id
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        return button
    }
    @discardableResult private func addTool(_ icon: MudiIcon?, _ label: String, id: String, title: String? = nil,
                                          action: ((UIButton) -> Void)? = nil) -> UIButton {
        let button = makeButton(icon, label, id: id, title: title)
        if let action { button.addAction(UIAction { [weak button] _ in if let button { action(button) } }, for: .touchUpInside) }
        tools.addArrangedSubview(button)
        return button
    }
    func prepareForOpening(target: String) {
        self.target = target; targetLabel.text = target
        toolbarScroll.setContentOffset(.zero, animated: false)
        confirmedText = nil
        textViewDidChange(input); updateMenus()
    }
    func setText(_ text: String) {
        input.text = text
        input.selectedRange = NSRange(location: text.utf16.count, length: 0)
        textViewDidChange(input)
    }
    func textViewDidChange(_ textView: UITextView) {
        confirmedText = nil; placeholder.isHidden = !input.text.isEmpty
        sendButton.setTitle(nil, for: .normal)
        sendButton.accessibilityLabel = "发送"
        sendButton.isEnabled = !input.text.isEmpty
        if wasEmpty != input.text.isEmpty {
            wasEmpty = input.text.isEmpty
            updateMenus()
        }
        updateStyle(); updateAvailableHeight()
    }
    override func layoutSubviews() { super.layoutSubviews(); updateAvailableHeight() }
    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        updateStyle(); updateAvailableHeight()
    }
    private func updateStyle() {
        backgroundColor = MudiPalette.raisedUI
        layer.borderColor = MudiPalette.borderUI.resolvedColor(with: traitCollection).cgColor
        input.font = MudiTypography.uiFont(15, compatibleWith: traitCollection); input.textColor = MudiPalette.inkUI
        input.tintColor = MudiPalette.sunsetUI
        placeholder.font = input.font; placeholder.textColor = MudiPalette.muteUI
        targetLabel.font = UIFontMetrics(forTextStyle: .caption2).scaledFont(for:
            TerminalFontRegistry.font(familyName: TerminalFontRegistry.defaultFamilyName, pointSize: 11) ?? MudiTypography.baseFont(11))
        targetLabel.textColor = MudiPalette.muteUI
        for button in tools.arrangedSubviews.compactMap({ $0 as? UIButton }) + pinned.arrangedSubviews.compactMap({ $0 as? UIButton }) {
            button.tintColor = MudiPalette.inkUI; button.setTitleColor(MudiPalette.inkUI, for: .normal)
        }
        sendButton.cap.layer.cornerRadius = 18
        sendButton.cap.backgroundColor = sendButton.isEnabled ? MudiPalette.sunsetUI : MudiPalette.inkUI.withAlphaComponent(0.16)
        sendButton.tintColor = sendButton.isEnabled ? MudiPalette.canvasUI : MudiPalette.muteUI
        sendButton.setTitleColor(sendButton.tintColor, for: .normal)
        sendButton.titleLabel?.font = MudiTypography.uiFont(13, weight: .semibold)
    }
    func updateAvailableHeight() {
        let width = max(bounds.width - 32, 1)
        let line = input.font?.lineHeight ?? 22
        let measured = input.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let header = targetLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let available = bar?.superview.map { parent in
            let top = parent.safeAreaInsets.top
            let keyboardTop = bar?.terminalView?.lastKeyboardFrameEnd.map { parent.convert($0, from: nil).minY } ?? parent.bounds.maxY
            return max(0, min(keyboardTop, parent.bounds.maxY) - top)
        } ?? .greatestFiniteMagnitude
        let height = max(line + 8, min(measured, line * 6 + 8, max(line + 8, available - header - 84)))
        input.isScrollEnabled = measured > height + 0.5
        inputHeight.constant = height
        let next = 8 + header + 2 + height + 2 + 44 + 4
        guard abs(next - preferredHeight) > 0.5 else { return }
        preferredHeight = next
        bar?.invalidateIntrinsicContentSize(); bar?.terminalView?.updateShortcutBarOffset()
    }
    private func send() {
        if input.markedTextRange != nil { input.unmarkText() }
        let text = input.text ?? ""
        guard !text.isEmpty, bar?.terminalView?.isInputFocusAllowed == true else { return }
        let lines = text.components(separatedBy: .newlines).count
        if lines > 20, confirmedText != text {
            confirmedText = text
            sendButton.setTitle("发送 \(lines) 行", for: .normal)
            sendButton.accessibilityLabel = "确认发送 \(lines) 行"
            return
        }
        remember(text, kind: "sent")
        bar?.sendComposedText(text, bracketedPaste: bracketedPaste, appendReturn: appendReturn)
        setText(""); bar?.closeCompose()
    }
    private func remember(_ text: String, kind: String) {
        guard !text.isEmpty else { return }
        var values = records.filter { !($0.text == text && $0.kind == kind) }
        values.insert(ComposerRecord(text: text, target: target, date: Date(), kind: kind), at: 0)
        records = values; updateMenus()
    }
    private func recordsMenu(kind: String) -> UIMenu {
        let actions = records.filter { $0.kind == kind }.map { record in
            UIAction(title: record.text, subtitle: record.target) { [weak self] _ in self?.setText(record.text) }
        }
        return UIMenu(title: kind == "draft" ? "草稿" : kind == "snippet" ? "片段" : "最近发送",
                      children: actions.isEmpty ? [UIAction(title: "暂无内容", attributes: .disabled) { _ in }] : actions)
    }
    private func updateMenus() {
        menuButtons["history"]?.menu = UIMenu(children: [recordsMenu(kind: "sent"), recordsMenu(kind: "draft")])
        menuButtons["snippet"]?.menu = UIMenu(children: [
            UIAction(title: "保存当前内容为片段", attributes: input.text.isEmpty ? .disabled : []) { [weak self] _ in
                guard let self else { return }; self.remember(self.input.text, kind: "snippet")
            }, recordsMenu(kind: "snippet")])
        menuButtons["insert"]?.menu = UIMenu(children: [
            UIAction(title: "粘贴") { [weak self] _ in self?.input.paste(nil) },
            UIAction(title: "插入 Tab") { [weak self] _ in self?.input.insertText("\t") }])
        menuButtons["target"]?.menu = UIMenu(children: [
            UIAction(title: target, state: .on) { _ in },
            UIAction(title: "选择 Pane") { [weak self] _ in self?.bar?.closeCompose(); self?.bar?.jumpToPanes() }])
        menuButtons.values.forEach { $0.showsMenuAsPrimaryAction = true }
        sendButton.menu = UIMenu(children: [
            UIAction(title: "发送后回车", subtitle: "发送完自动按 ↵", state: appendReturn ? .on : .off) { [weak self] _ in
                self?.appendReturn.toggle(); self?.updateMenus()
            },
            UIAction(title: "括号粘贴", subtitle: "终端支持时包裹多行输入", state: bracketedPaste ? .on : .off) { [weak self] _ in
                self?.bracketedPaste.toggle(); self?.updateMenus()
            },
            UIAction(title: "存为草稿") { [weak self] _ in
                guard let self else { return }; self.remember(self.input.text, kind: "draft")
            }])
    }
}
