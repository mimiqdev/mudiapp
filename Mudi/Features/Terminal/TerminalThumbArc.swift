import UIKit

@MainActor
final class MudiThumbArcOverlay: UIView {
    private var keys: [UIView] = []
    private let originView = UIImageView(image: MudiIcon.origin.uiImage)
    private let originDot = UIImageView(image: MudiIcon.originDot.uiImage)
    private let floatingLabel = UILabel()
    private var layout: ThumbArcLayout?
    private var preferences = ThumbArcPreferences()
    private(set) var selectedIndex: Int?
    private let feedback = UISelectionFeedbackGenerator()
    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        accessibilityIdentifier = "terminal-thumb-arc"
        originView.tintColor = MudiPalette.muteUI
        addSubview(originView)
        originDot.tintColor = MudiPalette.muteUI
        addSubview(originDot)
        floatingLabel.font = MudiTypography.uiFont(12)
        floatingLabel.textColor = MudiPalette.inkUI
        floatingLabel.backgroundColor = MudiPalette.raisedUI
        floatingLabel.textAlignment = .center
        floatingLabel.layer.cornerRadius = 14; floatingLabel.clipsToBounds = true
        addSubview(floatingLabel)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func begin(origin: CGPoint, preferences: ThumbArcPreferences) {
        self.preferences = preferences
        selectedIndex = nil
        keys.forEach { $0.removeFromSuperview() }; keys.removeAll()
        layout = ThumbArcLayout(origin: origin, bounds: bounds, count: preferences.actions.count, isLeftHanded: preferences.isLeftHanded)
        originView.frame = CGRect(x: origin.x - 6, y: origin.y - 6, width: 12, height: 12)
        originDot.frame = CGRect(x: origin.x - 2, y: origin.y - 2, width: 4, height: 4)
        floatingLabel.isHidden = true
        for (index, action) in preferences.actions.enumerated() {
            guard let center = layout?.centers[safe: index] else { continue }
            let key = UIView(frame: CGRect(x: center.x - 21, y: center.y - 21, width: 42, height: 42))
            key.layer.cornerRadius = 21
            key.layer.borderWidth = 1
            key.layer.borderColor = MudiPalette.inkUI.withAlphaComponent(0.22).resolvedColor(with: traitCollection).cgColor
            key.layer.shadowColor = UIColor.black.cgColor; key.layer.shadowOpacity = 0.25; key.layer.shadowRadius = 8
            let glass = MudiTerminalShortcutBar.makeMaterialView()
            glass.frame = key.bounds; glass.layer.cornerRadius = 21; glass.clipsToBounds = true
            key.addSubview(glass)
            if let icon = action.icon, let image = icon.uiImage {
                let view = UIImageView(image: image)
                view.tintColor = MudiPalette.inkUI
                view.frame = CGRect(origin: CGPoint(x: (42 - image.size.width) / 2, y: (42 - image.size.height) / 2), size: image.size)
                key.addSubview(view)
            } else {
                let label = UILabel(frame: key.bounds)
                label.text = action.glyph; label.font = MudiTypography.uiFont(action.glyph.count > 3 ? 11 : 14, weight: .medium)
                label.textColor = MudiPalette.inkUI; label.textAlignment = .center
                key.addSubview(label)
            }
            key.accessibilityLabel = action.title + " · " + action.detail
            addSubview(key); keys.append(key)
        }
        bringSubviewToFront(floatingLabel)
        feedback.prepare()
    }
    func select(at point: CGPoint) {
        let newIndex = layout?.selectedIndex(at: point)
        guard newIndex != selectedIndex else { return }
        selectedIndex = newIndex
        if preferences.hapticsEnabled, newIndex != nil { feedback.selectionChanged() }
        for (index, key) in keys.enumerated() {
            let selected = index == newIndex
            (key.subviews.first as? UIVisualEffectView)?.effect = selected ? nil : MudiTerminalShortcutBar.makeMaterialView().effect
            key.subviews.first?.backgroundColor = selected ? MudiPalette.sunsetUI : .clear
            key.layer.borderColor = (selected ? MudiPalette.sunsetUI : MudiPalette.inkUI.withAlphaComponent(0.22)).resolvedColor(with: traitCollection).cgColor
            for view in key.subviews.dropFirst() {
                (view as? UILabel)?.textColor = selected ? MudiPalette.canvasUI : MudiPalette.inkUI
                (view as? UIImageView)?.tintColor = selected ? MudiPalette.canvasUI : MudiPalette.inkUI
            }
            key.transform = selected && !UIAccessibility.isReduceMotionEnabled ? CGAffineTransform(scaleX: 1.16, y: 1.16) : .identity
        }
        guard let index = newIndex, let key = keys[safe: index] else { floatingLabel.isHidden = true; return }
        let action = preferences.actions[index]
        floatingLabel.text = "\(action.title)  \(action.detail)"
        let size = floatingLabel.sizeThatFits(CGSize(width: 220, height: 28))
        let width = min(size.width + 22, bounds.width - 16)
        let x = preferences.isLeftHanded ? key.frame.maxX + 10 : key.frame.minX - width - 10
        floatingLabel.frame = CGRect(x: min(max(x, 8), bounds.width - width - 8), y: min(max(key.frame.midY - 14, 8), bounds.height - 36), width: width, height: 28)
        floatingLabel.isHidden = false
    }
    func finish() -> ThumbArcAction? {
        let action = selectedIndex.flatMap { preferences.actions[safe: $0] }
        removeFromSuperview(); selectedIndex = nil
        return action
    }
    func cancel() { _ = finish() }
}

@MainActor
extension ShellTerminalView {
    func installThumbArcGesture() {
        let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleThumbArc(_:)))
        recognizer.numberOfTapsRequired = 1
        recognizer.minimumPressDuration = 0.08
        recognizer.allowableMovement = 20
        recognizer.delegate = self
        addGestureRecognizer(recognizer)
        thumbArcRecognizer = recognizer
    }
    @objc func handleThumbArc(_ gesture: UILongPressGestureRecognizer) {
        guard isInputFocusAllowed, let container = superview else { thumbArcOverlay.cancel(); return }
        let point = gesture.location(in: container)
        switch gesture.state {
        case .began:
            guard !thumbArcPreferences.actions.isEmpty else { return }
            shortcutBar?.activePopup = .none; shortcutBar?.clearModifiers()
            thumbArcOverlay.frame = frame
            container.addSubview(thumbArcOverlay)
            thumbArcOverlay.begin(origin: thumbArcOverlay.convert(point, from: container), preferences: thumbArcPreferences)
        case .changed:
            thumbArcOverlay.select(at: thumbArcOverlay.convert(point, from: container))
        case .ended:
            thumbArcOverlay.select(at: thumbArcOverlay.convert(point, from: container))
            if let action = thumbArcOverlay.finish() { executeThumbArcAction(action) }
        case .cancelled, .failed:
            thumbArcOverlay.cancel()
        default: break
        }
    }
    func executeThumbArcAction(_ action: ThumbArcAction) {
        guard isInputFocusAllowed, let bar = shortcutBar else { return }
        switch action {
        case .escape: bar.send([0x1b])
        case .controlC: bar.send([0x03])
        case .shiftTab: bar.send([0x1b, 0x5b, 0x5a])
        case .cursorUp: bar.handle(.cursorUp)
        case .paste: bar.pasteClipboard()
        case .jumpTo: onOpenPanePicker?()
        case .tab: bar.send([0x09])
        case .controlD: bar.send([0x04])
        case .controlZ: bar.send([0x1a])
        case .controlL: bar.send([0x0c])
        case .cursorDown: bar.handle(.cursorDown)
        case .cursorLeft: bar.handle(.cursorLeft)
        case .cursorRight: bar.handle(.cursorRight)
        case .home: bar.handle(.home)
        case .end: bar.handle(.end)
        case .pageUp: bar.handle(.pageUp)
        case .pageDown: bar.handle(.pageDown)
        case .customText: bar.sendComposedText(thumbArcPreferences.customText)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
