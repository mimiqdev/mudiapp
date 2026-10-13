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
        stopHardwareKeyRepeat()
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

}

/// Hardware keyboard routing. Mirrors SwiftTerm 1.15 (`dd2fb8ac`)
/// `iOSTerminalView.pressesBegan` key-by-key decisions (with Mudi's
/// `ShellTerminalView` PageUp/Down override), but every byte is produced by
/// the real VT encoder from its current modes and goes to the same PTY via
/// `submitKey`. Plain text, Return and Backspace are NOT handled here: they
/// stay with UIKit's text system (insertText/deleteBackward) so a key is never
/// sent twice. While marked text exists every press belongs to the IME.
@MainActor
extension GhosttyVTView {
    enum HardwareKeyAction {
        case key(GhosttyVt.Terminal.KeyEvent)
        case page(TerminalScrollDirection)
    }

    /// Returns the presses this view did not consume; callers forward those to
    /// `super` so UIKit text input and responder key commands still see them.
    func handleHardwarePresses(_ presses: Set<UIPress>) -> Set<UIPress> {
        guard isInputFocusAllowed, markedTextRange == nil else { return presses }
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key, let action = hardwareKeyAction(for: key) else {
                unhandled.insert(press)
                continue
            }
            switch action {
            case .key(let event):
                submitKey(event)
                startHardwareKeyRepeat(event)
            case .page(let direction):
                stopHardwareKeyRepeat()
                handleHardwarePage(direction)
            }
        }
        return unhandled
    }

    func stopHardwareKeyRepeat() {
        hardwareKeyRepeat?.invalidate()
        hardwareKeyRepeat = nil
    }

    func hardwareKeyAction(for key: UIKey) -> HardwareKeyAction? {
        let flags = key.modifierFlags
        let ignoring = key.charactersIgnoringModifiers
        if (try? terminal.status().kittyKeyboardFlags.isEmpty) == false {
            return kittyHardwareKeyAction(for: key)
        }
        typealias Event = GhosttyVt.Terminal.KeyEvent
        switch key.keyCode {
        case .keyboardUpArrow: return .key(Event(key: .arrowUp))
        case .keyboardDownArrow: return .key(Event(key: .arrowDown))
        case .keyboardLeftArrow, .keyboardRightArrow:
            let left = key.keyCode == .keyboardLeftArrow
            if flags.contains(.alternate) { return .key(Self.metaEvent(left ? "b" : "f")) } // emacs word motion
            return .key(Event(key: left ? .arrowLeft : .arrowRight, modifiers: flags.contains(.control) ? .control : []))
        case .keyboardPageUp: return .page(.up)
        case .keyboardPageDown: return .page(.down)
        case .keyboardHome: return .key(Event(key: .home))
        case .keyboardEnd: return .key(Event(key: .end))
        case .keyboardDeleteForward: return .key(Event(key: .delete))
        case .keyboardEscape: return .key(Event(key: .escape))
        case .keyboardTab: return .key(Event(key: .tab, modifiers: flags.contains(.shift) ? .shift : []))
        case .keyboardF1, .keyboardF2, .keyboardF3, .keyboardF4, .keyboardF5, .keyboardF6,
             .keyboardF7, .keyboardF8, .keyboardF9, .keyboardF10, .keyboardF11:
            return .key(Event(key: .function(UInt8(key.keyCode.rawValue - UIKeyboardHIDUsage.keyboardF1.rawValue + 1))))
        default:
            // SwiftTerm ignores Insert/F12+/media/modifier keys here; they
            // fall through to UIKit. Option is Meta (SwiftTerm's default
            // optionAsMetaKey); the shortcut-bar Meta latch has the same role.
            if flags.contains([.alternate, .command]) && ignoring == "o" { return nil }
            if flags.contains(.alternate) || metaModifier {
                return ignoring.isEmpty ? nil : .key(Self.metaEvent(ignoring))
            }
            if flags.contains(.control) { return Self.controlEvent(ignoring).map { .key($0) } }
            return nil
        }
    }

    /// Kitty keyboard protocol active: like SwiftTerm, functional keys and
    /// Ctrl/Option text carry all modifiers to the (kitty-aware) VT encoder.
    private func kittyHardwareKeyAction(for key: UIKey) -> HardwareKeyAction? {
        let flags = key.modifierFlags
        var modifiers: GhosttyVt.Terminal.Modifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.alternate) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.alphaShift) { modifiers.insert(.capsLock) }
        let functional: GhosttyVt.Terminal.KeyEvent.Key?
        switch key.keyCode {
        case .keyboardUpArrow: functional = .arrowUp
        case .keyboardDownArrow: functional = .arrowDown
        case .keyboardLeftArrow: functional = .arrowLeft
        case .keyboardRightArrow: functional = .arrowRight
        case .keyboardPageUp:
            if scrollCapability != .none || !isApplicationCursorMode { return .page(.up) }
            functional = .pageUp
        case .keyboardPageDown:
            if scrollCapability != .none || !isApplicationCursorMode { return .page(.down) }
            functional = .pageDown
        case .keyboardHome: functional = .home
        case .keyboardEnd: functional = .end
        case .keyboardInsert: functional = .insert
        case .keyboardDeleteForward: functional = .delete
        case .keyboardEscape: functional = .escape
        case .keyboardTab: functional = .tab
        default:
            let first = UIKeyboardHIDUsage.keyboardF1.rawValue, last = UIKeyboardHIDUsage.keyboardF12.rawValue
            let extended = UIKeyboardHIDUsage.keyboardF13.rawValue...UIKeyboardHIDUsage.keyboardF24.rawValue
            if (first...last).contains(key.keyCode.rawValue) {
                functional = .function(UInt8(key.keyCode.rawValue - first + 1))
            } else if extended.contains(key.keyCode.rawValue) {
                functional = .function(UInt8(key.keyCode.rawValue - extended.lowerBound + 13))
            } else {
                functional = nil
            }
        }
        if let functional { return .key(.init(key: functional, modifiers: modifiers)) }
        let text = key.charactersIgnoringModifiers
        guard flags.contains(.control) || flags.contains(.alternate), !text.isEmpty else { return nil }
        return .key(.init(key: .text, text: text, modifiers: modifiers,
                          unshiftedCodepoint: text.unicodeScalars.count == 1 ? text.unicodeScalars.first?.value : nil))
    }

    /// ESC-prefixed Meta text via the VT legacy Alt-prefix encoding.
    private static func metaEvent(_ text: String) -> GhosttyVt.Terminal.KeyEvent {
        .init(key: .text, text: text, modifiers: .option,
              unshiftedCodepoint: text.unicodeScalars.count == 1 ? text.unicodeScalars.first?.value : nil)
    }

    /// SwiftTerm's `applyControlToEventCharacters` set (letters, space,
    /// `\ ] [ ^ _ 6`). Ghostty's legacy encoder emits CSI u for Ctrl+I/M/[
    /// (fixterms), so those three map to the VT Tab/Enter/Escape keys, which
    /// produce SwiftTerm's C0 bytes (09/0D/1B). Other characters are left
    /// to UIKit text input, exactly like SwiftTerm.
    private static func controlEvent(_ characters: String) -> GhosttyVt.Terminal.KeyEvent? {
        guard characters.unicodeScalars.count == 1, let scalar = characters.unicodeScalars.first, scalar.isASCII else { return nil }
        let lower = Character(scalar).lowercased()
        switch lower {
        case "i": return .init(key: .tab)
        case "m": return .init(key: .enter)
        case "[": return .init(key: .escape)
        case "a"..."z", " ", "\\", "]", "^", "_", "6":
            return .init(key: .text, text: lower, modifiers: .control, unshiftedCodepoint: lower.unicodeScalars.first?.value)
        default: return nil
        }
    }

    /// DECCKM as the VT encoder currently applies it (the facade exposes
    /// no mode getter); used only for SwiftTerm's PageUp/Down rule.
    var isApplicationCursorMode: Bool {
        (try? terminal.encode(.init(key: .arrowUp))) == Data("\u{1b}OA".utf8)
    }

    /// Herdr/Mosh-wheel owners scroll by visible rows (ShellTerminalView's
    /// override); a plain session pages local VT history unless the app enabled
    /// application cursor mode, in which case the VT key goes to the PTY.
    func handleHardwarePage(_ direction: TerminalScrollDirection) {
        if scrollCapability == .none, isApplicationCursorMode {
            submitKey(.init(key: direction == .up ? .pageUp : .pageDown))
            return
        }
        scrollTerminal(direction: direction, lines: max(1, Int(screen.size.rows)),
                       location: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    /// SwiftTerm repeats a held handled key after 0.4 s every 0.1 s until
    /// release; UIKit itself delivers pressesBegan only once.
    private func startHardwareKeyRepeat(_ event: GhosttyVt.Terminal.KeyEvent) {
        stopHardwareKeyRepeat()
        let repeated = GhosttyVt.Terminal.KeyEvent(key: event.key, text: event.text, action: .repeatPress,
            modifiers: event.modifiers, unshiftedCodepoint: event.unshiftedCodepoint)
        let timer = Timer(fire: Date(timeIntervalSinceNow: 0.4), interval: 0.1, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated {
                guard self.isInputFocusAllowed, self.markedTextRange == nil else {
                    self.stopHardwareKeyRepeat()
                    return
                }
                self.onInput?(.key(repeated))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hardwareKeyRepeat = timer
    }
}

extension TerminalRGBColor {
    var vtColor: TerminalFrame.RGBColor { .init(red: red, green: green, blue: blue) }
}
