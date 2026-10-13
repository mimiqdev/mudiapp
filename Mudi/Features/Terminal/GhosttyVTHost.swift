import GhosttyVt
import HerdrKit
import UIKit

@MainActor
extension GhosttyVTView: TerminalHost {
    var hostView: UIView { self }
    var session: SSHShellSession? { sessionAdapter?.session }

    func send(_ bytes: [UInt8]) {
        guard isInputFocusAllowed, !bytes.isEmpty else { return }
        onInput?(.raw(Data(bytes)))
    }
    override func paste(_ sender: Any?) {
        guard isInputFocusAllowed, markedTextRange == nil, let text = UIPasteboard.general.string else { return }
        onInput?(.paste(text, bracketed: true, appendEnter: false))
    }
    func sendCursorKey(normal: [UInt8], application: [UInt8], final: UInt8) {
        let key: GhosttyVt.Terminal.KeyEvent.Key
        switch final {
        case 0x41: key = .arrowUp
        case 0x42: key = .arrowDown
        case 0x43: key = .arrowRight
        case 0x44: key = .arrowLeft
        default: return
        }
        submitKey(.init(key: key, modifiers: inputModifiers))
    }
    func sendComposedText(_ text: String, bracketedPaste: Bool, appendReturn: Bool) {
        guard isInputFocusAllowed, !text.isEmpty else { return }
        onInput?(.paste(text, bracketed: bracketedPaste, appendEnter: appendReturn))
    }
    func updateInputFocus(isAllowed: Bool) {
        isInputFocusAllowed = isAllowed
        if !isAllowed {
            shortcutBar?.composer?.input.resignFirstResponder()
            _ = resignFirstResponder()
        } else {
            restoreHostInputFocusIfRequested()
        }
    }
    func restoreHostInputFocusIfRequested() {
        guard shouldRestoreInputFocus, isInputFocusAllowed, window != nil, !isHidden else { return }
        shouldRestoreInputFocus = false
        if !isFirstResponder { _ = becomeFirstResponder() }
    }
    func requestTerminalRelayout() { setNeedsLayout(); setNeedsDisplay() }

    func start(session: SSHShellSession, onError: @escaping (String) -> Void, onClosed: @escaping () -> Void) {
        guard sessionAdapter == nil else { return }
        onHostError = onError
        onHostClosed = onClosed
        suppressFocusCallbacks = false
        let identity = ObjectIdentifier(session)
        let adapter = GhosttyVTSessionAdapter(view: self, session: session)
        sessionAdapter = adapter
        adapter.onError = { [weak self] error in
            guard let self, self.session.map(ObjectIdentifier.init) == identity else { return }
            self.onHostError?(error.localizedDescription)
        }
        adapter.onClosed = { [weak self] in
            guard let self, self.session.map(ObjectIdentifier.init) == identity else { return }
            self.onHostClosed?()
        }
        adapter.onBell = { UIAccessibility.post(notification: .announcement, argument: "Terminal bell") }
        adapter.start()
        restoreHostInputFocusIfRequested()
    }
    func updateSession(session: SSHShellSession, onError: @escaping (String) -> Void, onClosed: @escaping () -> Void) {
        onHostError = onError
        onHostClosed = onClosed
        guard self.session.map(ObjectIdentifier.init) != ObjectIdentifier(session) else { return }
        // Keep the same view, VT state and first responder. Retire only the
        // old pump/input generation; the connection owner handles disconnect.
        sessionAdapter?.stop()
        sessionAdapter = nil
        start(session: session, onError: onError, onClosed: onClosed)
    }
    func stop() {
        suppressFocusCallbacks = true
        shortcutBar?.composer?.input.resignFirstResponder()
        thumbArcController?.cancel()
        sessionAdapter?.stop()
        sessionAdapter = nil
        onHostError = nil
        onHostClosed = nil
    }

    func apply(theme: TerminalTheme) throws {
        let palette = try TerminalVTPalette.colors(for: theme)
        try terminal.setDefaultTheme(.init(foreground: theme.defaultForeground.vtColor,
            background: theme.defaultBackground.vtColor, cursor: theme.cursor.vtColor, palette: palette))
        appliedTheme = theme
        try refresh()
        shortcutBar?.updateAppearance(background: theme.defaultBackground.uiColor, foreground: theme.defaultForeground.uiColor)
    }

    // Same persistent bar policy as SwiftTerm: no input accessory, no hidden
    // parser/view. The chrome reserves its complete strip above the keyboard.
    func installHostKeyboardObserver() {
        keyboardObserver = TerminalNotificationToken(NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification,
            object: nil, queue: .main) { [weak self] notification in
                let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
                let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval ?? 0
                let curve = notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt ?? 0
                MainActor.assumeIsolated {
                    self?.updateShortcutBarOffset(keyboardFrameEnd: frame, animationDuration: duration, animationCurve: curve)
                }
            })
    }
    func ensureHostShortcutBarAttached() {
        guard window != nil, let container = superview, let bar = shortcutBar else { return }
        if bar.superview !== container {
            bar.removeFromSuperview()
            container.addSubview(bar)
            bar.translatesAutoresizingMaskIntoConstraints = false
            let bottom = bar.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            let height = bar.heightAnchor.constraint(equalToConstant: bar.preferredHeight)
            barBottomConstraint = bottom
            barHeightConstraint = height
            NSLayoutConstraint.activate([bottom, height])
            bar.applyCapsuleLayout(MudiShortcutBarCapsulePolicy.resolved(for: bar.traitCollection), in: container)
        }
        updateShortcutBarOffset()
    }
    func updateShortcutBarOffset(keyboardFrameEnd: CGRect? = nil, animationDuration: TimeInterval = 0, animationCurve: UInt = 0) {
        if let keyboardFrameEnd { lastKeyboardFrameEnd = keyboardFrameEnd }
        guard let bar = shortcutBar, let container = bar.superview, let bottom = barBottomConstraint else { return }
        var offset = container.safeAreaInsets.bottom + (bar.capsulePolicy?.bottomMargin ?? 0)
        if let frame = lastKeyboardFrameEnd, container.window != nil {
            let top = container.convert(frame, from: nil).minY
            if top < container.bounds.maxY - 0.5 { offset = max(0, container.bounds.maxY - top) }
        }
        barHeightConstraint?.constant = bar.preferredHeight
        (container as? TerminalChromeView)?.setReservedBottom(offset + bar.preferredHeight)
        guard abs(bottom.constant + offset) > 0.25 else { return }
        bottom.constant = -offset
        if animationDuration > 0 {
            UIView.animate(withDuration: animationDuration, delay: 0,
                options: UIView.AnimationOptions(rawValue: animationCurve << 16).union(.beginFromCurrentState)) {
                    container.layoutIfNeeded()
                }
        } else { container.setNeedsLayout() }
    }

    var hostKeyCommands: [UIKeyCommand]? {
        guard markedTextRange == nil, isInputFocusAllowed else { return nil }
        var commands: [UIKeyCommand] = []
        let inputs = [UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow, UIKeyCommand.inputLeftArrow,
            UIKeyCommand.inputRightArrow, UIKeyCommand.inputEscape, "\t", "\r", "\u{7f}"]
        for flags: UIKeyModifierFlags in [[], .control, .alternate, [.control, .alternate], .shift] {
            commands += inputs.map { UIKeyCommand(input: $0, modifierFlags: flags, action: #selector(handleHostHardwareKey(_:))) }
        }
        commands += (97...122).compactMap { UnicodeScalar($0) }.map {
            UIKeyCommand(input: String($0), modifierFlags: .control, action: #selector(handleHostHardwareKey(_:)))
        }
        return commands
    }
    @objc func handleHostHardwareKey(_ command: UIKeyCommand) {
        guard isInputFocusAllowed, markedTextRange == nil, let input = command.input else { return }
        var modifiers = inputModifiers
        if command.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if command.modifierFlags.contains(.alternate) { modifiers.insert(.option) }
        if command.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        let key: GhosttyVt.Terminal.KeyEvent.Key
        switch input {
        case UIKeyCommand.inputUpArrow: key = .arrowUp
        case UIKeyCommand.inputDownArrow: key = .arrowDown
        case UIKeyCommand.inputLeftArrow: key = .arrowLeft
        case UIKeyCommand.inputRightArrow: key = .arrowRight
        case UIKeyCommand.inputEscape: key = .escape
        case "\t": key = .tab
        case "\r": key = .enter
        case "\u{7f}": key = .backspace
        default: key = .text
        }
        submitKey(.init(key: key, text: key == .text ? input : nil, modifiers: modifiers,
                        unshiftedCodepoint: input.unicodeScalars.count == 1 ? input.unicodeScalars.first?.value : nil))
    }
}

extension TerminalRGBColor {
    var vtColor: TerminalFrame.RGBColor { .init(red: red, green: green, blue: blue) }
}
