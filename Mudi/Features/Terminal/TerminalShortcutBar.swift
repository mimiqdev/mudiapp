import UIKit
@preconcurrency import SwiftTerm

/// Which floating popup the shortcut bar currently shows. At most one is
/// visible at a time: opening any popup replaces the previous one, and
/// closing it returns the state to `.none`. Adding a future popup-style
/// key only requires a new case - there is no pairwise exclusion logic.
enum MudiShortcutPopup: Equatable {
    case none
    case ctrlCombo
    case dPad
}

/// Persistent, single-row, single-page terminal shortcut bar.
///
/// The bar is a plain view pinned above the bottom edge of the terminal's
/// container (ShellTerminalView installs it and rides it above the keyboard
/// frame); it is deliberately NOT a UIInputView any more — the system input
/// material misbehaved with the floating overlays (ghost frames). The
/// backdrop is Liquid Glass on iOS 26+ with an ultra-thin material fallback.
/// The fixed seven-item model is Esc, Tab, Ctrl (latch), direction (D-pad),
/// paste, Jump To, keyboard toggle.
@MainActor
final class MudiTerminalShortcutBar: UIView {
    weak var terminalView: ShellTerminalView?
    let onJumpTo: () -> Void
    private let materialView: UIVisualEffectView
    let stackView = UIStackView()
    let dismissKeyboardButton = UIButton(type: .system)
    let compositionLabel = UILabel()
    private var buttons: [UIButton] = []
    var shortcutButtons: [UIButton] = []
    var isShowingComposition = false
    static let rowSpacing: CGFloat = 6
    weak var controlButton: UIButton?
    weak var dpadButton: UIButton?
    let comboPopup = MudiControlComboPopup()
    let dpadOverlay = MudiTerminalDPadOverlay()
    var foregroundColor = UIColor.label
    var normalBackgroundColor = UIColor.secondarySystemFill
    /// Last known keyboard visibility; drives the toggle glyph.
    var isKeyboardVisible = false
    /// iPad skips the IME composition strip entirely; iPhone keeps it.
    /// Settable so the behavior stays testable on any device.
    var isCompositionStripSuppressed = UIDevice.current.userInterfaceIdiom == .pad
    /// Resolved capsule geometry policy for the floating bar.
    internal(set) var capsulePolicy: MudiShortcutBarCapsulePolicy?
    var capsuleLeadingConstraint: NSLayoutConstraint?
    var capsuleTrailingConstraint: NSLayoutConstraint?
    var capsuleCenterXConstraint: NSLayoutConstraint?
    var capsuleWidthConstraint: NSLayoutConstraint?
    /// Whether the last applied capsule layout was the centered capped
    /// mode; bounds changes re-evaluate it (mode-stickiness fix).
    var lastAppliedCapsuleCentered = false
    /// Single source of truth for which popup is visible; applied to the
    /// views by applyPopupState().
    var activePopup: MudiShortcutPopup = .none
    var dpadLeadingConstraint: NSLayoutConstraint?
    var dpadBottomConstraint: NSLayoutConstraint?

    init(
        terminalView: ShellTerminalView,
        onJumpTo: @escaping () -> Void
    ) {
        self.terminalView = terminalView
        self.onJumpTo = onJumpTo
        materialView = Self.makeMaterialView()
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 44))
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
        installKeyboardGlyphObserver()
        refreshKeyboardGlyph()
        comboPopup.onCombo = { [weak self] byte in
            self?.send([byte])
        }
        dpadOverlay.onCommand = { [weak self] command in
            self?.handle(command)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// One symbol configuration for every bar icon so all glyphs render
    /// at the same size and weight.
    static let barSymbolConfiguration = UIImage.SymbolConfiguration(
        pointSize: 15,
        weight: .semibold,
        scale: .medium
    )

    static func makeMaterialView() -> UIVisualEffectView {
        if #available(iOS 26.0, *) {
            return UIVisualEffectView(effect: UIGlassEffect())
        }
        return UIVisualEffectView(
            effect: UIBlurEffect(style: .systemUltraThinMaterial)
        )
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 44)
    }

    /// The floating popups live above the bar's own bounds, so the bar must
    /// claim touches inside any visible overlay or UIKit's hit test stops
    /// at the bounds check and the buttons never receive taps.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if super.point(inside: point, with: event) { return true }
        for overlay in [comboPopup, dpadOverlay] where !overlay.isHidden {
            if overlay.frame.contains(point) { return true }
        }
        return false
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Fully rounded capsule ends; the shadow path follows the capsule.
        let radius = bounds.height / 2
        layer.cornerRadius = radius
        materialView.layer.cornerRadius = radius
        materialView.clipsToBounds = true
        layer.shadowPath = UIBezierPath(
            roundedRect: bounds,
            cornerRadius: radius
        ).cgPath
        refreshCapsuleModeForBoundsChange()
        reclampDPadAfterBoundsChange()
    }

    override func traitCollectionDidChange(
        _ previousTraitCollection: UITraitCollection?
    ) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.horizontalSizeClass
            != previousTraitCollection?.horizontalSizeClass {
            applyCapsuleLayoutIfPossible()
        }
    }
}

extension MudiTerminalShortcutBar {
    func updateAppearance(background: UIColor, foreground: UIColor) {
        // The backdrop is Liquid Glass / material; it adapts to the content
        // behind it, so the terminal palette only drives the accents.
        backgroundColor = .clear
        foregroundColor = foreground
        normalBackgroundColor = foreground.withAlphaComponent(0.14)
        compositionLabel.textColor = foregroundColor
        compositionLabel.backgroundColor = normalBackgroundColor
        for button in buttons {
            button.tintColor = foregroundColor
            style(button)
        }
    }

    private func setupView() {
        setupMaterial()
        setupStack()
        addShortcutButtons()
        addCompositionLabel()
        addDismissKeyboardButton()
        addOverlays()
    }

    private func setupMaterial() {
        materialView.translatesAutoresizingMaskIntoConstraints = false
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.15
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 4)
        addSubview(materialView)
        NSLayoutConstraint.activate([
            materialView.leadingAnchor.constraint(equalTo: leadingAnchor),
            materialView.trailingAnchor.constraint(equalTo: trailingAnchor),
            materialView.topAnchor.constraint(equalTo: topAnchor),
            materialView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func setupStack() {
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.spacing = Self.rowSpacing

        addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: 8
            ),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor),
            stackView.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 4),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4)
        ])
    }

    private func addShortcutButtons() {
        addButton(
            symbolName: "escape",
            identifier: "terminal-shortcut-escape",
            label: "Escape",
            action: #selector(sendEscape)
        )
        addButton(
            symbolName: "arrow.right.to.line",
            identifier: "terminal-shortcut-tab",
            label: "Tab",
            action: #selector(sendTab)
        )
        controlButton = addButton(
            symbolName: "control",
            identifier: "terminal-shortcut-control",
            label: "Control modifier",
            action: #selector(toggleControl)
        )
        dpadButton = addButton(
            symbolName: "arrow.up.and.down.and.arrow.left.and.right",
            identifier: "terminal-shortcut-dpad",
            label: "Direction pad",
            action: #selector(toggleDPad)
        )
        addButton(
            symbolName: "doc.on.clipboard",
            identifier: "terminal-shortcut-paste",
            label: "Paste",
            action: #selector(pasteClipboard)
        )
        addButton(
            symbolName: "rectangle.stack",
            identifier: "terminal-shortcut-jump-to",
            label: "Jump To",
            action: #selector(jumpToPanes)
        )
    }

    private func addDismissKeyboardButton() {
        dismissKeyboardButton.translatesAutoresizingMaskIntoConstraints = false
        dismissKeyboardButton.setImage(
            UIImage(systemName: "keyboard.chevron.compact.down")?
                .applyingSymbolConfiguration(Self.barSymbolConfiguration),
            for: .normal
        )
        dismissKeyboardButton.accessibilityIdentifier = "terminal-shortcut-dismiss-keyboard"
        dismissKeyboardButton.accessibilityLabel = "Keyboard"
        dismissKeyboardButton.addTarget(
            self,
            action: #selector(toggleKeyboard),
            for: .touchUpInside
        )
        dismissKeyboardButton.layer.cornerRadius = 6
        addSubview(dismissKeyboardButton)
        buttons.append(dismissKeyboardButton)
        let preferredDismissWidth = dismissKeyboardButton.widthAnchor.constraint(
            equalToConstant: 40
        )
        preferredDismissWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            dismissKeyboardButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            dismissKeyboardButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            preferredDismissWidth,
            dismissKeyboardButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 24),
            dismissKeyboardButton.heightAnchor.constraint(equalToConstant: 32),
            stackView.trailingAnchor.constraint(
                lessThanOrEqualTo: dismissKeyboardButton.leadingAnchor,
                constant: -6
            )
        ])
        style(dismissKeyboardButton)
    }

    private func addOverlays() {
        for overlay in [comboPopup, dpadOverlay] {
            overlay.translatesAutoresizingMaskIntoConstraints = false
            addSubview(overlay)
        }
        let dpadLeading = dpadOverlay.leadingAnchor.constraint(
            equalTo: leadingAnchor,
            constant: 12
        )
        let dpadBottom = dpadOverlay.bottomAnchor.constraint(
            equalTo: topAnchor,
            constant: -12
        )
        dpadLeadingConstraint = dpadLeading
        dpadBottomConstraint = dpadBottom
        NSLayoutConstraint.activate([
            comboPopup.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            comboPopup.bottomAnchor.constraint(equalTo: topAnchor, constant: -8),
            comboPopup.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            dpadLeading,
            dpadBottom,
            dpadOverlay.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8)
        ])

        let drag = UIPanGestureRecognizer(
            target: self,
            action: #selector(handleDPadDrag(_:))
        )
        dpadOverlay.addGestureRecognizer(drag)
    }

    /// Drag-to-reposition for the floating D-pad card. Translation is
    /// accumulated into the leading/bottom anchor constants and clamped so
    /// the card stays inside the bar's horizontal span and above it.
    @discardableResult
    private func addButton(
        symbolName: String,
        identifier: String,
        label: String,
        action: Selector
    ) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(
            UIImage(systemName: symbolName)?
                .applyingSymbolConfiguration(Self.barSymbolConfiguration),
            for: .normal
        )
        button.accessibilityIdentifier = identifier
        button.accessibilityLabel = label
        button.addTarget(self, action: action, for: .touchUpInside)
        button.layer.cornerRadius = 6
        // Preferred 40pt but compressible: on narrow layouts the six
        // buttons shrink evenly instead of breaking the constraints.
        let preferredWidth = button.widthAnchor.constraint(equalToConstant: 40)
        preferredWidth.priority = .defaultHigh
        preferredWidth.isActive = true
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        // Compression (749) yields to the preferred width (750) only
        // under real stack pressure; low hugging keeps icons from
        // collapsing to intrinsic size (the composition-cycle regression).
        button.setContentCompressionResistancePriority(
            UILayoutPriority(749),
            for: .horizontal
        )
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stackView.addArrangedSubview(button)
        buttons.append(button)
        shortcutButtons.append(button)
        style(button)
        return button
    }
}
