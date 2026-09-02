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
        layer.cornerRadius = 10
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.2
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: 2)

        let backdrop = MudiTerminalShortcutBar.makeMaterialView()
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.layer.cornerRadius = 10
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
        button.backgroundColor = .tertiarySystemFill
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

/// Floating directional pad overlay toggled by the shortcut bar's direction
/// button: four direction keys, center Enter, and PgUp/PgDn. Every key sends
/// its sequence through the existing terminal input path.
@MainActor
final class MudiTerminalDPadOverlay: UIView {
    enum Command {
        case cursorUp
        case cursorDown
        case cursorLeft
        case cursorRight
        case enter
        case pageUp
        case pageDown
    }

    var onCommand: ((Command) -> Void)?

    private let backdropView: UIVisualEffectView

    init() {
        backdropView = MudiTerminalShortcutBar.makeMaterialView()
        super.init(frame: .zero)
        accessibilityIdentifier = "terminal-dpad-overlay"
        isHidden = true
        // Floating card: transparent container, material backdrop, soft
        // shadow. It hovers above the terminal and may cover content.
        backgroundColor = .clear
        layer.cornerRadius = 12
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 4)

        backdropView.translatesAutoresizingMaskIntoConstraints = false
        backdropView.layer.cornerRadius = 12
        backdropView.clipsToBounds = true
        addSubview(backdropView)

        let content = UIStackView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.axis = .horizontal
        content.alignment = .center
        content.spacing = 6
        addSubview(content)

        content.addArrangedSubview(directionGrid())
        content.addArrangedSubview(pageColumn())

        NSLayoutConstraint.activate([
            backdropView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdropView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdropView.topAnchor.constraint(equalTo: topAnchor),
            backdropView.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            content.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -6
            ),
            content.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: 6
            ),
            content.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -6
            )
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath(
            roundedRect: bounds,
            cornerRadius: layer.cornerRadius
        ).cgPath
    }

    private func directionGrid() -> UIStackView {
        let grid = UIStackView()
        grid.axis = .vertical
        grid.alignment = .center
        grid.spacing = 6
        grid.addArrangedSubview(row([spacer(), arrow(.cursorUp), spacer()]))
        grid.addArrangedSubview(
            row(
                [
                    arrow(.cursorLeft),
                    arrow(.enter),
                    arrow(.cursorRight),
                ]
            )
        )
        grid.addArrangedSubview(row([spacer(), arrow(.cursorDown), spacer()]))
        return grid
    }

    private func row(_ buttons: [UIView]) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: buttons)
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 6
        return stack
    }

    private func pageColumn() -> UIStackView {
        let column = UIStackView()
        column.axis = .vertical
        column.alignment = .center
        column.spacing = 6
        column.addArrangedSubview(arrow(.pageUp))
        column.addArrangedSubview(arrow(.pageDown))
        return column
    }

    private func arrow(_ command: Command) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(
            UIImage(systemName: Self.symbol(for: command)),
            for: .normal
        )
        button.accessibilityIdentifier = "terminal-dpad-\(Self.identifier(for: command))"
        button.accessibilityLabel = Self.label(for: command)
        button.backgroundColor = .tertiarySystemFill
        button.layer.cornerRadius = 7
        button.widthAnchor.constraint(equalToConstant: 32).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        button.addAction(
            UIAction { [weak self] _ in
                self?.onCommand?(command)
            },
            for: .touchUpInside
        )
        return button
    }

    private func spacer() -> UIView {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: 32).isActive = true
        return view
    }

    private static func symbol(for command: Command) -> String {
        switch command {
        case .cursorUp: "chevron.up"
        case .cursorDown: "chevron.down"
        case .cursorLeft: "chevron.left"
        case .cursorRight: "chevron.right"
        case .enter: "return"
        case .pageUp: "arrow.up.to.line"
        case .pageDown: "arrow.down.to.line"
        }
    }

    private static func identifier(for command: Command) -> String {
        switch command {
        case .cursorUp: "up"
        case .cursorDown: "down"
        case .cursorLeft: "left"
        case .cursorRight: "right"
        case .enter: "enter"
        case .pageUp: "page-up"
        case .pageDown: "page-down"
        }
    }

    private static func label(for command: Command) -> String {
        switch command {
        case .cursorUp: "Cursor up"
        case .cursorDown: "Cursor down"
        case .cursorLeft: "Cursor left"
        case .cursorRight: "Cursor right"
        case .enter: "Return"
        case .pageUp: "Page up"
        case .pageDown: "Page down"
        }
    }
}
