import UIKit

@MainActor
final class MudiThumbArcOverlay: UIView {
    private var keys: [UIView] = []
    private let originView = UIImageView(image: MudiIcon.origin.uiImage)
    private let originDot = UIImageView(image: MudiIcon.originDot.uiImage)
    private let floatingGlass = MudiTerminalShortcutBar.makeMaterialView()
    private let floatingLabel = UILabel()
    private var layout: ThumbArcLayout?
    private var preferences = ThumbArcPreferences()
    private var isActivated = false
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
        floatingLabel.textAlignment = .center
        floatingGlass.layer.cornerRadius = 14
        floatingGlass.clipsToBounds = true
        floatingGlass.contentView.addSubview(floatingLabel)
        floatingGlass.accessibilityIdentifier = "terminal-thumb-arc-label"
        addSubview(floatingGlass)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: MudiThumbArcOverlay, _: UITraitCollection) in
            view.refreshKeys()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func begin(origin: CGPoint, preferences: ThumbArcPreferences) {
        self.preferences = preferences
        selectedIndex = nil; isActivated = false
        keys.forEach { $0.removeFromSuperview() }; keys.removeAll()
        layout = ThumbArcLayout(origin: origin, bounds: bounds, count: preferences.actions.count, isLeftHanded: preferences.isLeftHanded)
        originView.frame = CGRect(x: origin.x - 18, y: origin.y - 18, width: 36, height: 36)
        originDot.frame = CGRect(x: origin.x - 2, y: origin.y - 2, width: 4, height: 4)
        floatingGlass.isHidden = true
        for (index, action) in preferences.actions.enumerated() {
            guard let center = layout?.centers[safe: index] else { continue }
            let key = UIView(frame: CGRect(x: center.x - 16, y: center.y - 16, width: 32, height: 32))
            let glass = MudiTerminalShortcutBar.makeMaterialView()
            glass.clipsToBounds = true
            key.addSubview(glass)
            if let image = action.arcIcon?.uiImage {
                let view = UIImageView(image: image)
                view.tintColor = MudiPalette.inkUI
                key.addSubview(view)
            } else {
                let label = UILabel()
                label.text = action.glyph
                label.textAlignment = .center
                label.adjustsFontSizeToFitWidth = true
                label.minimumScaleFactor = 0.6
                key.addSubview(label)
            }
            key.accessibilityLabel = action.title + " · " + action.detail
            addSubview(key); keys.append(key)
        }
        refreshKeys()
        bringSubviewToFront(floatingGlass)
        if preferences.hapticsEnabled { feedback.prepare() }
    }

    func select(at point: CGPoint) {
        guard let layout else { return }
        let distance = hypot(point.x - layout.origin.x, point.y - layout.origin.y)
        if distance < ThumbArcLayout.cancelRadius { isActivated = false }
        else if distance >= preferences.activationDistance.points { isActivated = true }
        let newIndex = layout.selectedIndex(at: point, previous: selectedIndex,
            activationDistance: preferences.activationDistance.points, isActivated: isActivated)
        guard newIndex != selectedIndex else { return }
        selectedIndex = newIndex
        if preferences.hapticsEnabled, newIndex != nil { feedback.selectionChanged(); feedback.prepare() }
        refreshKeys()
    }

    private func refreshKeys() {
        for (index, key) in keys.enumerated() {
            let selected = index == selectedIndex
            let size: CGFloat = selected ? 38 : 32
            key.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            key.layer.cornerRadius = size / 2
            key.layer.borderWidth = selected ? 0.776 : 0.762
            key.layer.borderColor = (selected ? MudiPalette.sunsetUI : MudiPalette.glassLineUI).resolvedColor(with: traitCollection).cgColor
            key.layer.shadowColor = (selected ? MudiPalette.sunsetUI : UIColor.black).resolvedColor(with: traitCollection).cgColor
            key.layer.shadowOpacity = selected ? 0.7 : MudiPalette.glassShadowOpacity(in: traitCollection)
            key.layer.shadowRadius = selected ? 10.857 : 12.19
            key.layer.shadowOffset = selected ? .zero : CGSize(width: 0, height: 4.571)
            if let glass = key.subviews.first as? UIVisualEffectView {
                glass.frame = key.bounds; glass.layer.cornerRadius = size / 2
                glass.effect = selected ? nil : MudiTerminalShortcutBar.makeMaterialView().effect
                glass.backgroundColor = selected ? MudiPalette.sunsetUI : .clear
            }
            for view in key.subviews.dropFirst() {
                let color = selected ? MudiPalette.canvasUI : MudiPalette.inkUI
                if let label = view as? UILabel {
                    let action = preferences.actions[index]
                    let normalSize: CGFloat = action == .escape ? 9.143 : action.glyph.count > 3 ? 9 : 10.667
                    label.font = MudiTypography.uiFont(selected ? 10.857 : normalSize, weight: .semibold)
                    label.textColor = color
                    label.frame = key.bounds.insetBy(dx: 3, dy: 0)
                } else if let imageView = view as? UIImageView, let image = imageView.image {
                    imageView.tintColor = color
                    imageView.frame = CGRect(origin: CGPoint(x: (size - image.size.width) / 2, y: (size - image.size.height) / 2), size: image.size)
                }
            }
        }
        updateFloatingLabel()
    }

    private func updateFloatingLabel() {
        guard let index = selectedIndex, let key = keys[safe: index], let layout else {
            floatingGlass.isHidden = true; return
        }
        let action = preferences.actions[index]
        let text = NSMutableAttributedString(string: action.title, attributes: [
            .font: MudiTypography.uiFont(13, weight: .semibold), .foregroundColor: MudiPalette.sunsetUI
        ])
        text.append(NSAttributedString(string: "  " + action.detail, attributes: [
            .font: MudiTypography.uiFont(12), .foregroundColor: MudiPalette.adaptive(0xDADBDF, 0x3A3C40)
        ]))
        floatingLabel.attributedText = text
        let content = floatingLabel.sizeThatFits(CGSize(width: max(0, bounds.width - 38), height: 80))
        let size = CGSize(width: min(content.width + 22, max(0, bounds.width - 16)), height: content.height + 12)
        let dx = key.center.x - layout.origin.x, dy = key.center.y - layout.origin.y
        let distance = max(hypot(dx, dy), 1)
        let vx = dx / distance, vy = dy / distance
        let offset = 29 + abs(vx) * size.width / 2 + abs(vy) * size.height / 2
        let center = CGPoint(x: key.center.x + vx * offset, y: key.center.y + vy * offset)
        floatingGlass.frame = CGRect(x: min(max(center.x - size.width / 2, 8), bounds.width - size.width - 8),
            y: min(max(center.y - size.height / 2, 8), bounds.height - size.height - 8), width: size.width, height: size.height)
        floatingLabel.frame = floatingGlass.bounds.insetBy(dx: 11, dy: 6)
        floatingGlass.layer.borderWidth = 1
        floatingGlass.layer.borderColor = MudiPalette.glassLineUI.resolvedColor(with: traitCollection).cgColor
        floatingGlass.isHidden = false
    }

    func finish() -> ThumbArcAction? {
        let action = selectedIndex.flatMap { preferences.actions[safe: $0] }
        removeFromSuperview(); selectedIndex = nil; isActivated = false
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
