import UIKit
@preconcurrency import SwiftTerm

/// A compact, horizontally scrolling input accessory for terminal-only keys.
/// SwiftTerm's stock accessory covers most of this surface, but this bar also
/// exposes Alt, clipboard actions, and selection without requiring a hardware
/// keyboard.
@MainActor
final class MudiTerminalShortcutBar: UIInputView {
    private weak var terminalView: TerminalView?
    private let onPageUp: () -> Void
    private let onPageDown: () -> Void
    private let scrollView = UIScrollView()
    private let stackView = UIStackView()
    private let dismissKeyboardButton = UIButton(type: .system)
    private let compositionLabel = UILabel()
    private var buttons: [UIButton] = []
    private var shortcutButtons: [UIButton] = []
    private var isShowingComposition = false
    private var shortcutContentOffset = CGPoint.zero
    private weak var controlButton: UIButton?
    private weak var altButton: UIButton?
    private weak var mouseButton: UIButton?
    private var foregroundColor = UIColor.label
    private var normalBackgroundColor = UIColor.secondarySystemFill

    init(
        terminalView: TerminalView,
        onPageUp: @escaping () -> Void,
        onPageDown: @escaping () -> Void
    ) {
        self.terminalView = terminalView
        self.onPageUp = onPageUp
        self.onPageDown = onPageDown
        super.init(
            frame: CGRect(x: 0, y: 0, width: 0, height: 44),
            inputViewStyle: .keyboard
        )
        allowsSelfSizing = true
        accessibilityIdentifier = "terminal-shortcut-bar"
        setupView()
        updateAppearance(background: .systemBackground, foreground: .label)
        updateModifierState()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(modifierDidReset(_:)),
            name: .terminalViewControlModifierReset,
            object: terminalView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(modifierDidReset(_:)),
            name: .terminalViewMetaModifierReset,
            object: terminalView
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 44)
    }
}

extension MudiTerminalShortcutBar {
    func updateAppearance(background: UIColor, foreground: UIColor) {
        backgroundColor = background
        foregroundColor = foreground
        normalBackgroundColor = foreground.withAlphaComponent(0.14)
        compositionLabel.textColor = foregroundColor
        compositionLabel.backgroundColor = normalBackgroundColor
        for button in buttons {
            button.setTitleColor(foregroundColor, for: .normal)
            button.setTitleColor(.white, for: .selected)
            button.tintColor = foregroundColor
            style(button)
        }
    }

    func updateComposition(markedText: String?) {
        let text = markedText?.isEmpty == false ? markedText : nil
        let wasShowingComposition = isShowingComposition
        let shouldShowComposition = text != nil

        if shouldShowComposition, !wasShowingComposition {
            shortcutContentOffset = scrollView.contentOffset
        }
        isShowingComposition = shouldShowComposition
        compositionLabel.text = text
        compositionLabel.isHidden = !shouldShowComposition
        compositionLabel.accessibilityLabel = text.map { "Composing \($0)" }
        shortcutButtons.forEach { $0.isHidden = shouldShowComposition }

        if shouldShowComposition {
            setNeedsLayout()
            layoutIfNeeded()
            let maximumOffset = max(0, scrollView.contentSize.width - scrollView.bounds.width)
            scrollView.setContentOffset(
                CGPoint(x: maximumOffset, y: scrollView.contentOffset.y),
                animated: false
            )
        } else if wasShowingComposition {
            setNeedsLayout()
            layoutIfNeeded()
            scrollView.setContentOffset(shortcutContentOffset, animated: false)
        }
    }

    @objc private func modifierDidReset(_ notification: Notification) {
        updateModifierState()
    }

    private func setupView() {
        setupScrollView()
        addShortcutButtons()
        addCompositionLabel()
        addDismissKeyboardButton()
    }

    private func setupScrollView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.alwaysBounceVertical = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.isDirectionalLockEnabled = true

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.spacing = 6

        addSubview(scrollView)
        scrollView.addSubview(stackView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stackView.leadingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.leadingAnchor,
                constant: 8
            ),
            stackView.trailingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.trailingAnchor,
                constant: -8
            ),
            stackView.topAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.topAnchor,
                constant: 6
            ),
            stackView.bottomAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.bottomAnchor,
                constant: -6
            )
        ])
    }

    private func addShortcutButtons() {
        addModifierButtons()
        addNavigationButtons()
        addClipboardButtons()
        addMouseButton()
    }

    private func addModifierButtons() {
        let esc = addButton(
            title: "Esc",
            identifier: "terminal-shortcut-escape",
            action: #selector(sendEscape)
        )
        esc.accessibilityLabel = "Escape"

        controlButton = addButton(
            title: "Ctrl",
            identifier: "terminal-shortcut-control",
            action: #selector(toggleControl)
        )
        controlButton?.accessibilityLabel = "Control modifier"

        altButton = addButton(
            title: "Alt",
            identifier: "terminal-shortcut-alt",
            action: #selector(toggleAlt)
        )
        altButton?.accessibilityLabel = "Alt modifier"

        let tab = addButton(
            title: "Tab",
            identifier: "terminal-shortcut-tab",
            action: #selector(sendTab)
        )
        tab.accessibilityLabel = "Tab"
    }

    private func addNavigationButtons() {
        addButton(
            title: "←",
            identifier: "terminal-shortcut-left",
            action: #selector(sendLeft)
        ).accessibilityLabel = "Left arrow"
        addButton(
            title: "↓",
            identifier: "terminal-shortcut-down",
            action: #selector(sendDown)
        ).accessibilityLabel = "Down arrow"
        addButton(
            title: "↑",
            identifier: "terminal-shortcut-up",
            action: #selector(sendUp)
        ).accessibilityLabel = "Up arrow"
        addButton(
            title: "→",
            identifier: "terminal-shortcut-right",
            action: #selector(sendRight)
        ).accessibilityLabel = "Right arrow"
        addButton(
            title: "PgUp",
            identifier: "terminal-shortcut-page-up",
            action: #selector(sendPageUp)
        )
        addButton(
            title: "PgDn",
            identifier: "terminal-shortcut-page-down",
            action: #selector(sendPageDown)
        )
    }

    private func addClipboardButtons() {
        addButton(
            title: "Copy",
            identifier: "terminal-shortcut-copy",
            action: #selector(copySelection)
        )
        addButton(
            title: "Paste",
            identifier: "terminal-shortcut-paste",
            action: #selector(pasteClipboard)
        )
        addButton(
            title: "Select All",
            identifier: "terminal-shortcut-select-all",
            action: #selector(selectAllText)
        )
    }

    private func addMouseButton() {
        mouseButton = addButton(
            title: "Mouse",
            identifier: "terminal-shortcut-mouse",
            action: #selector(toggleMouseReporting)
        )
        mouseButton?.accessibilityLabel = "Mouse reporting"
    }

    private func addCompositionLabel() {
        compositionLabel.translatesAutoresizingMaskIntoConstraints = false
        compositionLabel.font = UIFont.monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize,
            weight: .regular
        )
        compositionLabel.adjustsFontForContentSizeCategory = true
        compositionLabel.numberOfLines = 1
        compositionLabel.lineBreakMode = .byClipping
        compositionLabel.textAlignment = .left
        compositionLabel.isHidden = true
        compositionLabel.accessibilityIdentifier = "terminal-ime-composition"
        compositionLabel.accessibilityTraits = [.staticText]
        compositionLabel.setContentHuggingPriority(.required, for: .horizontal)
        compositionLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        compositionLabel.heightAnchor.constraint(equalToConstant: 32).isActive = true
        stackView.addArrangedSubview(compositionLabel)
    }

    private func addDismissKeyboardButton() {
        dismissKeyboardButton.translatesAutoresizingMaskIntoConstraints = false
        dismissKeyboardButton.setImage(
            UIImage(systemName: "keyboard.chevron.compact.down"),
            for: .normal
        )
        dismissKeyboardButton.accessibilityIdentifier = "terminal-shortcut-dismiss-keyboard"
        dismissKeyboardButton.accessibilityLabel = "Hide keyboard"
        dismissKeyboardButton.addTarget(
            self,
            action: #selector(dismissKeyboard),
            for: .touchUpInside
        )
        dismissKeyboardButton.layer.cornerRadius = 6
        addSubview(dismissKeyboardButton)
        buttons.append(dismissKeyboardButton)
        NSLayoutConstraint.activate([
            dismissKeyboardButton.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -8
            ),
            dismissKeyboardButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            dismissKeyboardButton.widthAnchor.constraint(equalToConstant: 44),
            dismissKeyboardButton.heightAnchor.constraint(equalToConstant: 32),
            scrollView.trailingAnchor.constraint(
                equalTo: dismissKeyboardButton.leadingAnchor,
                constant: -6
            )
        ])
        style(dismissKeyboardButton)
    }

    @discardableResult
    private func addButton(
        title: String,
        identifier: String,
        action: Selector
    ) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle(title, for: .normal)
        button.accessibilityIdentifier = identifier
        button.titleLabel?.font = UIFont.preferredFont(forTextStyle: .caption1)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.addTarget(self, action: action, for: .touchUpInside)
        button.layer.cornerRadius = 6
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 0,
            leading: 9,
            bottom: 0,
            trailing: 9
        )
        button.configuration = configuration
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        stackView.addArrangedSubview(button)
        buttons.append(button)
        shortcutButtons.append(button)
        return button
    }

    private func style(_ button: UIButton) {
        let backgroundColor = button.isSelected
            ? UIColor.systemBlue
            : normalBackgroundColor
        let titleColor = button.isSelected ? UIColor.white : foregroundColor
        button.backgroundColor = backgroundColor
        button.setTitleColor(titleColor, for: .normal)
        button.setTitleColor(.white, for: .selected)
        var configuration = button.configuration
        configuration?.baseBackgroundColor = backgroundColor
        configuration?.baseForegroundColor = titleColor
        button.configuration = configuration
        button.accessibilityTraits = button.isSelected
            ? [.button, .selected]
            : [.button]
    }

    private func updateModifierState() {
        guard let terminalView else { return }
        controlButton?.isSelected = terminalView.controlModifier
        altButton?.isSelected = terminalView.metaModifier
        mouseButton?.isSelected = !terminalView.allowMouseReporting
        for button in [controlButton, altButton, mouseButton].compactMap({ $0 }) {
            style(button)
        }
    }

    private func clearModifiers() {
        terminalView?.controlModifier = false
        terminalView?.metaModifier = false
        updateModifierState()
    }

    private func insert(_ text: String) {
        terminalView?.insertText(text)
        updateModifierState()
    }

    private func send(_ bytes: [UInt8]) {
        terminalView?.send(bytes)
        clearModifiers()
    }

    private func sendArrow(
        normal: [UInt8],
        application: [UInt8],
        final: UInt8
    ) {
        guard let terminalView else { return }
        if terminalView.controlModifier || terminalView.metaModifier {
            let modifier: UInt8
            switch (terminalView.controlModifier, terminalView.metaModifier) {
            case (true, true):
                modifier = 0x37
            case (true, false):
                modifier = 0x35
            case (false, true):
                modifier = 0x33
            case (false, false):
                modifier = 0x31
            }
            terminalView.send([0x1b, 0x5b, 0x31, 0x3b, modifier, final])
            clearModifiers()
            return
        }
        terminalView.send(
            terminalView.getTerminal().applicationCursor ? application : normal
        )
    }

    @objc private func sendEscape() {
        send([0x1b])
    }

    @objc private func toggleControl() {
        terminalView?.controlModifier.toggle()
        updateModifierState()
    }

    @objc private func toggleAlt() {
        terminalView?.metaModifier.toggle()
        updateModifierState()
    }

    @objc private func sendTab() {
        insert("\t")
    }

    @objc private func sendLeft() {
        sendArrow(
            normal: EscapeSequences.moveLeftNormal,
            application: EscapeSequences.moveLeftApp,
            final: 0x44
        )
    }

    @objc private func sendDown() {
        sendArrow(
            normal: EscapeSequences.moveDownNormal,
            application: EscapeSequences.moveDownApp,
            final: 0x42
        )
    }

    @objc private func sendUp() {
        sendArrow(
            normal: EscapeSequences.moveUpNormal,
            application: EscapeSequences.moveUpApp,
            final: 0x41
        )
    }

    @objc private func sendRight() {
        sendArrow(
            normal: EscapeSequences.moveRightNormal,
            application: EscapeSequences.moveRightApp,
            final: 0x43
        )
    }

    @objc private func sendPageUp() {
        onPageUp()
    }

    @objc private func sendPageDown() {
        onPageDown()
    }

    @objc private func dismissKeyboard() {
        terminalView?.resignFirstResponder()
    }

    @objc private func copySelection() {
        terminalView?.copy(nil)
    }

    @objc private func pasteClipboard() {
        terminalView?.paste(nil)
    }

    @objc private func selectAllText() {
        terminalView?.selectAll(nil)
    }

    @objc private func toggleMouseReporting() {
        terminalView?.allowMouseReporting.toggle()
        updateModifierState()
    }
}
