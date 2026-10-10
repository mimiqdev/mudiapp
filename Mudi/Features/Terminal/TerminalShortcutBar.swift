import UIKit
@preconcurrency import SwiftTerm

enum MudiShortcutPopup: Equatable { case none, ctrlCombo, dPad }

/// Scrollable terminal actions on the left; navigation and keyboard stay pinned.
@MainActor
final class MudiTerminalShortcutBar: UIView {
    weak var terminalView: ShellTerminalView?
    let onJumpTo: () -> Void
    private let materialView = UIView()
    let stackView = UIStackView()
    let scrollView = MudiKeyScrollView()
    let pinnedStackView = UIStackView()
    let dismissKeyboardButton = MudiKeyButton(type: .custom)
    let compositionLabel = UILabel()
    private var buttons: [UIButton] = []
    var shortcutButtons: [UIButton] = []
    var isShowingComposition = false
    static let rowSpacing: CGFloat = 5
    weak var controlButton: UIButton?
    weak var dpadButton: UIButton?
    let comboPopup = MudiControlComboPopup()
    let dpadOverlay = MudiTerminalDPadOverlay()
    var foregroundColor = MudiPalette.inkUI
    var normalBackgroundColor = MudiPalette.keyUI
    var isKeyboardVisible = false
    var isCompositionStripSuppressed = UIDevice.current.userInterfaceIdiom == .pad
    var capsulePolicy: MudiShortcutBarCapsulePolicy?
    var capsuleLeadingConstraint: NSLayoutConstraint?
    var capsuleTrailingConstraint: NSLayoutConstraint?
    var capsuleCenterXConstraint: NSLayoutConstraint?
    var capsuleWidthConstraint: NSLayoutConstraint?
    var lastAppliedCapsuleCentered = false
    var activePopup: MudiShortcutPopup = .none
    var dpadLeadingConstraint: NSLayoutConstraint?
    var dpadBottomConstraint: NSLayoutConstraint?
    var dpadRelativePosition: CGPoint?
    weak var dpadAnchorView: UIView?
    var lastDPadSafeBounds = CGRect.zero
    var composer: MudiComposerCard?
    var composeRestoresTerminalFocus = false
    var composeTargetLabel = "Terminal"
    var preferredHeight: CGFloat { composer?.isHidden == false ? (composer?.preferredHeight ?? 80) + 16 : 48 }
    let dividerView = UIView()
    private let topRule = UIView()
    func updateBackdropForComposer(_ visible: Bool) {
        materialView.isHidden = visible; topRule.isHidden = visible
    }

    init(terminalView: ShellTerminalView, onJumpTo: @escaping () -> Void) {
        self.terminalView = terminalView
        self.onJumpTo = onJumpTo
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 48))
        accessibilityIdentifier = "terminal-shortcut-bar"
        setupView()
        if let position = UserDefaults.standard.array(forKey: "com.mimiqdev.mudi.dpad-relative-position") as? [Double], position.count == 2 {
            dpadRelativePosition = CGPoint(x: min(max(position[0], 0), 1), y: min(max(position[1], 0), 1))
        }
        updateAppearance(background: .systemBackground, foreground: .label)
        updateModifierState()
        for name in [Notification.Name.terminalViewControlModifierReset, .terminalViewMetaModifierReset] {
            NotificationCenter.default.addObserver(self, selector: #selector(modifierDidReset(_:)), name: name, object: terminalView)
        }
        installKeyboardGlyphObserver()
        refreshKeyboardGlyph()
        comboPopup.onCombo = { [weak self] in self?.send([$0]) }
        dpadOverlay.onCommand = { [weak self] in self?.handle($0) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }
    static let barSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 15, weight: .medium, scale: .medium)
    static func makeMaterialView() -> UIVisualEffectView {
        if #available(iOS 26.0, *) {
            let effect = UIGlassEffect()
            effect.tintColor = MudiPalette.glassTintUI
            return UIVisualEffectView(effect: effect)
        }
        let view = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
        view.backgroundColor = MudiPalette.glassTintUI
        return view
    }
    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: preferredHeight) }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if super.point(inside: point, with: event) { return true }
        return [comboPopup, dpadOverlay].contains { !$0.isHidden && $0.frame.contains(point) }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let radius = (capsulePolicy ?? MudiShortcutBarCapsulePolicy.resolved(for: traitCollection))
            .capsuleLayout(containerWidth: superview?.bounds.width ?? bounds.width, barHeight: bounds.height).cornerRadius
        layer.cornerRadius = radius
        materialView.layer.cornerRadius = radius
        materialView.clipsToBounds = true
        topRule.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1)
        refreshCapsuleModeForBoundsChange()
        reclampDPadAfterBoundsChange()
        composer?.updateAvailableHeight()
    }
    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if traitCollection.horizontalSizeClass != previous?.horizontalSizeClass { applyCapsuleLayoutIfPossible() }
        updateAppearance(background: .systemBackground, foreground: .label)
    }
    func updateAppearance(background: UIColor, foreground: UIColor) {
        backgroundColor = .clear
        materialView.backgroundColor = MudiPalette.sheetUI
        foregroundColor = MudiPalette.inkUI
        normalBackgroundColor = MudiPalette.keyUI
        compositionLabel.textColor = foregroundColor
        compositionLabel.backgroundColor = normalBackgroundColor
        topRule.backgroundColor = MudiPalette.hairlineUI
        buttons.forEach { style($0) }
    }
    private func setupView() {
        materialView.accessibilityIdentifier = "terminal-shortcut-backdrop"
        materialView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(materialView)
        NSLayoutConstraint.activate([
            materialView.leadingAnchor.constraint(equalTo: leadingAnchor), materialView.trailingAnchor.constraint(equalTo: trailingAnchor),
            materialView.topAnchor.constraint(equalTo: topAnchor), materialView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        addSubview(topRule)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.contentInsetAdjustmentBehavior = .never
        addSubview(scrollView)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.spacing = Self.rowSpacing
        scrollView.addSubview(stackView)
        pinnedStackView.translatesAutoresizingMaskIntoConstraints = false
        pinnedStackView.axis = .horizontal
        pinnedStackView.alignment = .center
        pinnedStackView.spacing = 6
        addSubview(pinnedStackView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            scrollView.trailingAnchor.constraint(equalTo: pinnedStackView.leadingAnchor, constant: -12),
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stackView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
            pinnedStackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            pinnedStackView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        addButton(title: "Esc", identifier: "escape", label: "Escape", action: #selector(sendEscape))
        let tab = addButton(title: "Tab", identifier: "tab", label: "Tab · 长按反向 Tab", action: #selector(sendTab))
        tab.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(reverseTab(_:))))
        let hint = UILabel(frame: CGRect(x: 29, y: 0, width: 10, height: 11))
        hint.text = "⇧"; hint.font = MudiTypography.uiFont(8); hint.textColor = MudiPalette.muteUI
        hint.isUserInteractionEnabled = false; tab.addSubview(hint)
        controlButton = addButton(title: "Ctrl", identifier: "control", label: "Control modifier", action: #selector(toggleControl))
        dpadButton = addButton(icon: .move, identifier: "dpad", label: "Direction pad", action: #selector(toggleDPad))
        addButton(icon: .compose, identifier: "compose", label: "Compose", action: #selector(openCompose))
        addButton(icon: .paste, identifier: "paste", label: "Paste", action: #selector(pasteClipboard))
        addButton(icon: .history, identifier: "history", label: "上一条历史", action: #selector(recallHistory))
        addButton(icon: .layers, identifier: "jump-to", label: "Jump To", action: #selector(jumpToPanes), pinned: true)
        configure(dismissKeyboardButton, icon: .keyboardHide, title: nil, identifier: "dismiss-keyboard", label: "Keyboard", action: #selector(toggleKeyboard))
        pinnedStackView.addArrangedSubview(dismissKeyboardButton)
        buttons.append(dismissKeyboardButton)
        let divider = dividerView
        divider.backgroundColor = MudiPalette.borderUI
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)
        NSLayoutConstraint.activate([
            divider.widthAnchor.constraint(equalToConstant: 1), divider.heightAnchor.constraint(equalToConstant: 20),
            divider.centerYAnchor.constraint(equalTo: centerYAnchor), divider.trailingAnchor.constraint(equalTo: pinnedStackView.leadingAnchor, constant: -6)
        ])
        addCompositionLabel()
        addOverlays()
    }
    @discardableResult private func addButton(icon: MudiIcon? = nil, title: String? = nil, identifier: String, label: String, action: Selector, pinned: Bool = false) -> UIButton {
        let button = MudiKeyButton(type: .custom)
        configure(button, icon: icon, title: title, identifier: identifier, label: label, action: action)
        (pinned ? pinnedStackView : stackView).addArrangedSubview(button)
        buttons.append(button); shortcutButtons.append(button)
        return button
    }
    private func configure(_ button: UIButton, icon: MudiIcon?, title: String?, identifier: String, label: String, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(icon?.uiImage, for: .normal)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = MudiTypography.uiFont(14, weight: .medium, compatibleWith: traitCollection)
        button.accessibilityIdentifier = "terminal-shortcut-" + identifier
        button.accessibilityLabel = label
        button.addTarget(self, action: action, for: .touchUpInside)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        style(button)
    }
    private func addOverlays() {
        for overlay in [comboPopup, dpadOverlay] {
            overlay.translatesAutoresizingMaskIntoConstraints = false; addSubview(overlay)
        }
        let leading = dpadOverlay.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12)
        let bottom = dpadOverlay.bottomAnchor.constraint(equalTo: topAnchor, constant: -12)
        dpadLeadingConstraint = leading; dpadBottomConstraint = bottom
        NSLayoutConstraint.activate([
            comboPopup.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            comboPopup.bottomAnchor.constraint(equalTo: topAnchor, constant: -8),
            comboPopup.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            leading, bottom
        ])
        dpadOverlay.dragHandle.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handleDPadDrag(_:))))
    }
}
