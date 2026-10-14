import GameController
import UIKit

/// Uses the terminal's original responder so the system input-mode choice and
/// focus callback ownership survive the temporary keyboard replacement.
@MainActor
final class TerminalModifierKeyboard: UIInputView {
    enum Mode { case control, alt }
    var mode: Mode = .control { didSet { modeLabel.text = mode == .control ? "Ctrl" : "Alt" } }
    var onKey: ((String) -> Void)?
    var onCancel: (() -> Void)?
    let modeLabel = UILabel()
    let navigationScroll = MudiKeyScrollView()
    private var keyboardHeight: CGFloat
    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: keyboardHeight) }
    init(height: CGFloat) {
        keyboardHeight = 44
        super.init(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 44), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        accessibilityIdentifier = "terminal-modifier-keyboard"
        let content = UIStackView()
        content.axis = .vertical
        content.spacing = 7
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])
        let top = UIStackView()
        top.spacing = 8
        modeLabel.text = "Ctrl"
        modeLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        modeLabel.textAlignment = .center
        modeLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true
        top.addArrangedSubview(modeLabel)
        navigationScroll.showsHorizontalScrollIndicator = false
        let nav = UIStackView()
        nav.spacing = 6
        nav.translatesAutoresizingMaskIntoConstraints = false
        navigationScroll.addSubview(nav)
        NSLayoutConstraint.activate([
            nav.leadingAnchor.constraint(equalTo: navigationScroll.contentLayoutGuide.leadingAnchor),
            nav.trailingAnchor.constraint(equalTo: navigationScroll.contentLayoutGuide.trailingAnchor),
            nav.topAnchor.constraint(equalTo: navigationScroll.contentLayoutGuide.topAnchor),
            nav.bottomAnchor.constraint(equalTo: navigationScroll.contentLayoutGuide.bottomAnchor),
            nav.heightAnchor.constraint(equalTo: navigationScroll.frameLayoutGuide.heightAnchor)
        ])
        for key in ["Home", "End", "PgUp", "PgDn", "←", "→", "Tab", "Del"] {
            let button = makeKey(key)
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
            nav.addArrangedSubview(button)
        }
        top.addArrangedSubview(navigationScroll)
        top.heightAnchor.constraint(equalToConstant: 36).isActive = true
        content.addArrangedSubview(top)
        let cancel = makeKey(MudiL10n.text("取消"))
        cancel.widthAnchor.constraint(equalToConstant: 44).isActive = true
        top.addArrangedSubview(cancel)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    private func makeKey(_ label: String) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(label, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        button.backgroundColor = .tertiarySystemBackground
        button.setTitleColor(.label, for: .normal)
        button.layer.cornerRadius = 6
        button.accessibilityIdentifier = "modifier-key-" + label
        button.addAction(UIAction { [weak self] _ in
            if label == MudiL10n.text("取消") { self?.onCancel?() } else { self?.onKey?(label) }
        }, for: .touchUpInside)
        return button
    }
    static func bytes(for key: String, mode: Mode) -> [UInt8]? {
        let modifier = mode == .control ? "5" : "3"
        let navigation: [String: String] = ["Home": "\u{1b}[1;\(modifier)H", "End": "\u{1b}[1;\(modifier)F", "PgUp": "\u{1b}[5;\(modifier)~", "PgDn": "\u{1b}[6;\(modifier)~", "←": "\u{1b}[1;\(modifier)D", "→": "\u{1b}[1;\(modifier)C"]
        if let value = navigation[key] { return Array(value.utf8) }
        let normal: [UInt8]
        switch key {
        case "Tab": return Array("\u{1b}[27;\(modifier);9~".utf8)
        case "Del": normal = [127]
        case "Enter": normal = [13]
        case "Space": normal = [32]
        default:
            guard key.utf8.count == 1, let char = key.utf8.first, (32...126).contains(char) else { return nil }
            normal = [char]
        }
        if mode == .alt { return [27] + normal }
        if key == "Space" { return [0] }
        if key == "Enter" { return [10] }
        if key == "Del" { return [8] }
        guard let char = normal.first else { return nil }
        if char == 32 { return [0] }
        if char == 63 { return [127] }
        let upper = (97...122).contains(char) ? char - 32 : char
        guard (64...95).contains(upper) else { return nil }
        return [upper & 31]
    }
}

@MainActor
final class TerminalModifierInput: UITextField, UITextFieldDelegate {
    var onInput: ((String) -> Void)?
    var onRetire: (() -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        keyboardType = .asciiCapable
        autocorrectionType = .no
        spellCheckingType = .no
        autocapitalizationType = .none
        smartQuotesType = .no
        smartDashesType = .no
        textColor = .clear
        tintColor = .clear
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
        accessibilityIdentifier = "terminal-modifier-ascii-input"
        delegate = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        if string == "\n" { onInput?("Enter") }
        else if string.isEmpty { onInput?("Del") }
        else { onInput?(string) }
        return false
    }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool { onInput?("Enter"); return false }
    func textFieldDidEndEditing(_ textField: UITextField) { onRetire?() }
}

@MainActor
extension MudiTerminalShortcutBar {
    var isModifierInputActive: Bool { modifierInput?.isFirstResponder == true }
    func synchronizeModifierKeyboard() {
        guard !isUpdatingModifierInput, let host = terminalView else { return }
        let wantsKeyboard = (host.controlModifier || host.metaModifier) && host.isInputFocusAllowed && !isShowingComposition && composer?.isHidden != false && !isHardwareKeyboardConnected()
        if !wantsKeyboard {
            guard let input = modifierInput else { return }
            isUpdatingModifierInput = true
            modifierInput = nil
            modifierKeyboard = nil
            input.onRetire = nil
            host.isModifierFocusHandoff = true
            if input.isFirstResponder {
                if host.isInputFocusAllowed && UIApplication.shared.applicationState == .active && host.hostView.window != nil && window != nil {
                    _ = host.becomeFirstResponder()
                } else { input.resignFirstResponder() }
            }
            input.removeFromSuperview()
            host.isModifierFocusHandoff = false
            isUpdatingModifierInput = false
            return
        }
        guard window != nil else { return }
        if let keyboard = modifierKeyboard {
            keyboard.mode = host.metaModifier ? .alt : .control
            return
        }
        isUpdatingModifierInput = true
        defer { isUpdatingModifierInput = false }
        let keyboard = TerminalModifierKeyboard(height: 44)
        let input = TerminalModifierInput(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        modifierKeyboard = keyboard
        modifierInput = input
        modifierKeyboardSession = host.session.map(ObjectIdentifier.init)
        input.inputAccessoryView = keyboard
        addSubview(input)
        keyboard.onCancel = { [weak self, weak keyboard] in
            guard let self, self.modifierKeyboard === keyboard else { return }
            self.clearModifiers()
        }
        keyboard.onKey = { [weak self, weak keyboard] key in
            guard let self, self.modifierKeyboard === keyboard else { return }
            self.consumeModifierKey(key)
        }
        input.onInput = { [weak self, weak input] key in
            guard let self, self.modifierInput === input else { return }
            self.consumeModifierKey(key)
        }
        input.onRetire = { [weak self] in self?.clearModifiers() }
        keyboard.mode = host.metaModifier ? .alt : .control
        keyboard.navigationScroll.setContentOffset(.zero, animated: false)
        host.isModifierFocusHandoff = true
        let hadFocus = host.isFirstResponder
        let armed = input.becomeFirstResponder()
        host.isModifierFocusHandoff = false
        if !armed {
            input.removeFromSuperview()
            modifierInput = nil
            modifierKeyboard = nil
            host.controlModifier = false
            host.metaModifier = false
        } else if !hadFocus { host.onInputFocusChange?(true) }
        isKeyboardVisible = armed
        refreshKeyboardGlyph()
    }
    func consumeModifierKey(_ key: String) {
        guard let host = terminalView, host.isInputFocusAllowed,
              modifierKeyboard != nil, modifierKeyboardSession == host.session.map(ObjectIdentifier.init),
              (host.controlModifier || host.metaModifier) else { return }
        guard let bytes = TerminalModifierKeyboard.bytes(for: key, mode: host.metaModifier ? .alt : .control) else {
            clearModifiers()
            return
        }
        let prefix = host.metaModifier ? "Alt" : "Ctrl"
        host.send(bytes)
        clearModifiers()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let toast = UILabel()
        toast.text = MudiL10n.format("✓ 已发送 %@+%@", prefix, key.uppercased())
        toast.textAlignment = .center
        toast.font = .systemFont(ofSize: 12)
        toast.textColor = .label
        toast.backgroundColor = .secondarySystemBackground
        toast.layer.cornerRadius = 12
        toast.clipsToBounds = true
        if let container = superview {
            toast.frame = CGRect(x: max(16, (container.bounds.width - 180) / 2), y: max(0, frame.minY - 42), width: 180, height: 30)
            container.addSubview(toast)
            Task { @MainActor in try? await Task.sleep(for: .milliseconds(1500)); toast.removeFromSuperview() }
        }
    }
}
