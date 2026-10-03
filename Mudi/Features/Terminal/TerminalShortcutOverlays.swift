import UIKit

/// Floating popup of common Ctrl combo key caps shown while Ctrl is latched.
/// Tapping a combo sends the matching control byte through the terminal
/// input path and clears the latch.
@MainActor
final class MudiControlComboPopup: UIView {
    /// Plan contract note: the active plan enumerates the eight caps
    /// C D L A E U K W; Ctrl+J (0x0A) was added on explicit user request
    /// (device-feedback round 3) and the contract test was updated in
    /// step. Plan-text amendment is tracked by the reviewer.
    static let combos: [(label: String, byte: UInt8)] = [
        ("C", 0x03), ("D", 0x04), ("L", 0x0C), ("A", 0x01),
        ("E", 0x05), ("U", 0x15), ("K", 0x0B), ("W", 0x17),
        ("J", 0x0A),
    ]

    var onCombo: ((UInt8) -> Void)?
    private var comboButtons: [UIButton] = []
    private let stackView = UIStackView()

    init() {
        super.init(frame: .zero)
        accessibilityIdentifier = "terminal-control-combo-popup"
        isHidden = true
        backgroundColor = .clear
        layer.cornerRadius = 14
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.2
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: 2)

        let backdrop = MudiTerminalShortcutBar.makeMaterialView()
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.layer.cornerRadius = 14
        backdrop.clipsToBounds = true
        addSubview(backdrop)

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.spacing = 6
        addSubview(stackView)

        for combo in Self.combos {
            stackView.addArrangedSubview(comboButton(for: combo))
        }

        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            stackView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stackView.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -8
            ),
            stackView.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: 8
            ),
            stackView.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -8
            )
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for button in comboButtons {
            button.layer.borderColor = MudiPalette.borderUI.resolvedColor(with: traitCollection).cgColor
        }
        layer.shadowPath = UIBezierPath(
            roundedRect: bounds,
            cornerRadius: layer.cornerRadius
        ).cgPath
    }

    private func comboButton(for combo: (label: String, byte: UInt8)) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle(combo.label, for: .normal)
        button.titleLabel?.font = UIFont.monospacedSystemFont(
            ofSize: 15,
            weight: .semibold
        )
        button.accessibilityLabel = combo.label
        button.backgroundColor = MudiPalette.keyUI
        button.tintColor = MudiPalette.inkUI
        button.layer.borderWidth = 1
        button.layer.borderColor = MudiPalette.borderUI.cgColor
        button.layer.cornerRadius = 6
        button.addTarget(
            self,
            action: #selector(comboTapped(_:)),
            for: .touchUpInside
        )
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
        let preferredWidth = button.widthAnchor.constraint(equalToConstant: 32)
        // Preferred 32pt cap but compressible: on narrow layouts the popup
        // is capped at the bar's trailing edge, so the caps shrink evenly
        // instead of pushing the rightmost one past the container.
        preferredWidth.priority = .defaultHigh
        preferredWidth.isActive = true
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        comboButtons.append(button)
        return button
    }

    @objc private func comboTapped(_ sender: UIButton) {
        guard let index = comboButtons.firstIndex(of: sender) else { return }
        onCombo?(Self.combos[index].byte)
    }
}

/// Independent glass keys, with a drag handle and a lock. Corner keys can be configured with a long press.
@MainActor
final class MudiTerminalDPadOverlay: UIView {
    enum Command: Int, CaseIterable {
        case cursorUp, cursorDown, cursorLeft, cursorRight, enter, pageUp, pageDown
        case backspace, clearScreen, home, end
        var title: String {
            switch self {
            case .cursorUp: "Up"
            case .cursorDown: "Down"
            case .cursorLeft: "Left"
            case .cursorRight: "Right"
            case .enter: "Enter"
            case .pageUp: "Page Up"
            case .pageDown: "Page Down"
            case .backspace: "退格"
            case .clearScreen: "清屏"
            case .home: "Home"
            case .end: "End"
            }
        }
    }
    var onCommand: ((Command) -> Void)?
    let dragHandle = UIView()
    private let lockButton = UIButton(type: .system)
    private(set) var isLocked = false
    var isDragging = false { didSet { updateHandle() } }
    private var cornerCommands: [Command]
    private var cornerButtons: [UIButton] = []

    init() {
        cornerCommands = ["left", "right"].enumerated().map { index, side in
            let key = "dev.mudi.mobile.dpad-corner-" + side
            return UserDefaults.standard.object(forKey: key) != nil
                ? Command(rawValue: UserDefaults.standard.integer(forKey: key)) ?? (index == 0 ? .backspace : .clearScreen)
                : (index == 0 ? .backspace : .clearScreen)
        }
        super.init(frame: .zero)
        accessibilityIdentifier = "terminal-dpad-overlay"
        isHidden = true
        backgroundColor = .clear
        let content = UIStackView()
        content.axis = .vertical; content.alignment = .center; content.spacing = 8
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        setupHandle()
        content.addArrangedSubview(dragHandle)
        let rows: [[Command?]] = [[cornerCommands[0], .cursorUp, cornerCommands[1]], [.cursorLeft, .enter, .cursorRight], [nil, .cursorDown, nil]]
        for (rowIndex, row) in rows.enumerated() {
            let stack = UIStackView()
            stack.axis = .horizontal; stack.spacing = 6; stack.alignment = .center
            for (column, command) in row.enumerated() {
                if let command {
                    let corner = rowIndex == 0 && column != 1
                    let button = makeButton(command, corner: corner)
                    if corner {
                        button.tag = cornerButtons.count
                        cornerButtons.append(button)
                        configureCornerMenu(button, index: button.tag)
                    }
                    stack.addArrangedSubview(button)
                } else {
                    let spacer = UIView()
                    spacer.translatesAutoresizingMaskIntoConstraints = false
                    spacer.widthAnchor.constraint(equalToConstant: 46).isActive = true
                    stack.addArrangedSubview(spacer)
                }
            }
            content.addArrangedSubview(stack)
        }
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor), content.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor), content.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        updateHandle()
        for button in subviews.flatMap({ view in allButtons(in: view) }) {
            button.layer.borderColor = MudiPalette.inkUI.withAlphaComponent(0.22).resolvedColor(with: traitCollection).cgColor
        }
    }
    private func allButtons(in view: UIView) -> [UIButton] {
        (view as? UIButton).map { [$0] } ?? view.subviews.flatMap { allButtons(in: $0) }
    }
    private func setupHandle() {
        dragHandle.translatesAutoresizingMaskIntoConstraints = false
        let glass = MudiTerminalShortcutBar.makeMaterialView()
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.isUserInteractionEnabled = false
        glass.layer.cornerRadius = 12; glass.clipsToBounds = true
        dragHandle.addSubview(glass)
        dragHandle.layer.cornerRadius = 12
        dragHandle.layer.borderWidth = 1
        let grip = UIView()
        grip.backgroundColor = MudiPalette.muteUI; grip.layer.cornerRadius = 1.5
        grip.translatesAutoresizingMaskIntoConstraints = false
        dragHandle.addSubview(grip)
        lockButton.translatesAutoresizingMaskIntoConstraints = false
        lockButton.setImage(MudiIcon.unlock.uiImage, for: .normal)
        lockButton.accessibilityLabel = "锁定方向键位置"
        lockButton.accessibilityIdentifier = "terminal-dpad-lock"
        lockButton.addTarget(self, action: #selector(toggleLock), for: .touchUpInside)
        dragHandle.addSubview(lockButton)
        NSLayoutConstraint.activate([
            dragHandle.widthAnchor.constraint(equalToConstant: 64), dragHandle.heightAnchor.constraint(equalToConstant: 24),
            glass.leadingAnchor.constraint(equalTo: dragHandle.leadingAnchor), glass.trailingAnchor.constraint(equalTo: dragHandle.trailingAnchor),
            glass.topAnchor.constraint(equalTo: dragHandle.topAnchor), glass.bottomAnchor.constraint(equalTo: dragHandle.bottomAnchor),
            grip.leadingAnchor.constraint(equalTo: dragHandle.leadingAnchor, constant: 12), grip.centerYAnchor.constraint(equalTo: dragHandle.centerYAnchor),
            grip.widthAnchor.constraint(equalToConstant: 18), grip.heightAnchor.constraint(equalToConstant: 3),
            lockButton.trailingAnchor.constraint(equalTo: dragHandle.trailingAnchor, constant: -4),
            lockButton.topAnchor.constraint(equalTo: dragHandle.topAnchor), lockButton.bottomAnchor.constraint(equalTo: dragHandle.bottomAnchor),
            lockButton.widthAnchor.constraint(equalToConstant: 28)
        ])
        updateHandle()
    }
    @objc private func toggleLock() {
        isLocked.toggle()
        lockButton.setImage(isLocked ? UIImage(systemName: "lock.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12)) : MudiIcon.unlock.uiImage, for: .normal)
        lockButton.accessibilityValue = isLocked ? "已锁定" : "可拖动"
        lockButton.accessibilityTraits = isLocked ? [.button, .selected] : [.button]
        updateHandle()
    }
    private func updateHandle() {
        lockButton.tintColor = isLocked ? MudiPalette.sunsetUI : MudiPalette.muteUI
        dragHandle.layer.borderColor = (isDragging && !isLocked ? MudiPalette.sunsetUI : MudiPalette.inkUI.withAlphaComponent(0.22)).resolvedColor(with: traitCollection).cgColor
    }
    private func makeButton(_ command: Command, corner: Bool) -> UIButton {
        let button = UIButton(type: .custom)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.layer.cornerRadius = 15
        let glass = MudiTerminalShortcutBar.makeMaterialView()
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.isUserInteractionEnabled = false; glass.layer.cornerRadius = 15; glass.clipsToBounds = true
        button.insertSubview(glass, at: 0)
        if command == .enter { glass.effect = nil; glass.backgroundColor = MudiPalette.inkUI }
        button.tintColor = command == .enter ? MudiPalette.canvasUI : MudiPalette.inkUI
        button.layer.borderWidth = 1
        button.layer.borderColor = MudiPalette.inkUI.withAlphaComponent(0.22).cgColor
        let identifier: String
        switch command {
        case .cursorUp: identifier = "up"
        case .cursorDown: identifier = "down"
        case .cursorLeft: identifier = "left"
        case .cursorRight: identifier = "right"
        case .pageUp: identifier = "page-up"
        case .pageDown: identifier = "page-down"
        default: identifier = String(describing: command)
        }
        button.accessibilityIdentifier = "terminal-dpad-" + identifier
        button.accessibilityLabel = command.title
        configureGlyph(button, command: command)
        if let imageView = button.imageView { button.bringSubviewToFront(imageView) }
        button.addAction(UIAction { [weak self, weak button] _ in
            guard let self else { return }
            let value = corner ? self.cornerCommands[button?.tag ?? 0] : command
            self.onCommand?(value)
        }, for: .touchUpInside)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 46), button.heightAnchor.constraint(equalToConstant: 46),
            glass.leadingAnchor.constraint(equalTo: button.leadingAnchor), glass.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            glass.topAnchor.constraint(equalTo: button.topAnchor), glass.bottomAnchor.constraint(equalTo: button.bottomAnchor)
        ])
        return button
    }
    private func configureGlyph(_ button: UIButton, command: Command) {
        let icon: MudiIcon?
        switch command {
        case .cursorUp: icon = .dPadUp
        case .cursorDown: icon = .down
        case .cursorLeft: icon = .left
        case .cursorRight: icon = .right
        case .enter: icon = .enter
        case .backspace: icon = .backspace
        case .clearScreen: icon = .clear
        default: icon = nil
        }
        button.setImage(icon?.uiImage, for: .normal)
        button.setTitle(icon == nil ? command.title : nil, for: .normal)
        button.titleLabel?.font = MudiTypography.uiFont(11)
        button.setTitleColor(MudiPalette.inkUI, for: .normal)
    }
    func setCornerCommand(_ command: Command, index: Int) {
        guard cornerButtons.indices.contains(index), [.backspace, .clearScreen, .pageUp, .pageDown, .home, .end].contains(command) else { return }
        cornerCommands[index] = command
        UserDefaults.standard.set(command.rawValue, forKey: "dev.mudi.mobile.dpad-corner-" + (index == 0 ? "left" : "right"))
        let button = cornerButtons[index]
        configureGlyph(button, command: command)
        if let imageView = button.imageView { button.bringSubviewToFront(imageView) }
        button.accessibilityLabel = command.title
        configureCornerMenu(button, index: index)
    }
    private func configureCornerMenu(_ button: UIButton, index: Int) {
        let choices: [Command] = [.backspace, .clearScreen, .pageUp, .pageDown, .home, .end]
        button.menu = UIMenu(title: "角键操作", children: choices.map { command in
            UIAction(title: command.title, state: cornerCommands[index] == command ? .on : .off) { [weak self] _ in
                self?.setCornerCommand(command, index: index)
            }
        })
    }
}
