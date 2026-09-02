import UIKit
@preconcurrency import SwiftTerm

/// Key dispatch and latch/state rendering for MudiTerminalShortcutBar:
/// byte-sequence sending, arrow/application-cursor handling, modifier
/// latching (with the combo popup visibility) and the chip styling used
/// for latched states.
@MainActor
extension MudiTerminalShortcutBar {
    @objc func modifierDidReset(_: Notification) {
        updateModifierState()
    }

    /// Keyboard Shift-key behavior: the background stays untouched; the
    /// glyph alone carries the accent tint while latched/active.
    func style(_ button: UIButton?) {
        guard let button else { return }
        button.backgroundColor = .clear
        button.tintColor = button.isSelected ? .systemBlue : foregroundColor
        button.accessibilityTraits = button.isSelected
            ? [.button, .selected]
            : [.button]
    }

    func updateModifierState() {
        guard let terminalView else { return }
        // The latch was consumed (e.g. by keyboard input): close the popup
        // through the shared state so visibility and latch stay in
        // lockstep.
        if !terminalView.controlModifier, activePopup == .ctrlCombo {
            activePopup = .none
        }
        applyPopupState()
    }

    func clearModifiers() {
        terminalView?.controlModifier = false
        terminalView?.metaModifier = false
        updateModifierState()
    }

    func insert(_ text: String) {
        terminalView?.insertText(text)
        updateModifierState()
    }

    func send(_ bytes: [UInt8]) {
        terminalView?.send(bytes)
        clearModifiers()
    }

    func sendArrow(
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

    func handle(_ command: MudiTerminalDPadOverlay.Command) {
        switch command {
        case .cursorUp:
            sendArrow(normal: EscapeSequences.moveUpNormal, application: EscapeSequences.moveUpApp, final: 0x41)
        case .cursorDown:
            sendArrow(normal: EscapeSequences.moveDownNormal, application: EscapeSequences.moveDownApp, final: 0x42)
        case .cursorLeft:
            sendArrow(normal: EscapeSequences.moveLeftNormal, application: EscapeSequences.moveLeftApp, final: 0x44)
        case .cursorRight:
            sendArrow(normal: EscapeSequences.moveRightNormal, application: EscapeSequences.moveRightApp, final: 0x43)
        case .enter:
            send(EscapeSequences.cmdRet)
        case .pageUp:
            send(EscapeSequences.cmdPageUp)
        case .pageDown:
            send(EscapeSequences.cmdPageDown)
        }
    }

    @objc func sendEscape() {
        send([0x1b])
    }

    /// Applies the popup state to the views. The Ctrl case additionally
    /// requires the latch to be set, keeping the popup and the latch in
    /// lockstep through one code path.
    func applyPopupState() {
        let ctrlLatched = terminalView?.controlModifier == true
        comboPopup.isHidden = !(activePopup == .ctrlCombo && ctrlLatched)
        dpadOverlay.isHidden = activePopup != .dPad
        controlButton?.isSelected = activePopup == .ctrlCombo && ctrlLatched
        dpadButton?.isSelected = activePopup == .dPad
        style(controlButton)
        style(dpadButton)
        setNeedsLayout()
        layoutIfNeeded()
    }

    @objc func toggleControl() {
        guard let terminalView else { return }
        terminalView.controlModifier.toggle()
        if terminalView.controlModifier {
            // Opening the popup replaces whichever popup was open.
            activePopup = .ctrlCombo
        } else if activePopup == .ctrlCombo {
            activePopup = .none
        }
        applyPopupState()
    }

    @objc func toggleDPad() {
        let willShow = activePopup != .dPad
        if willShow {
            // Opening the D-pad replaces whichever popup was open and
            // clears a latched Ctrl so later arrows send unmodified
            // sequences exactly as the closed popup implies.
            activePopup = .dPad
            terminalView?.controlModifier = false
            anchorDPadNearDirectionButton()
        } else {
            activePopup = .none
        }
        applyPopupState()
    }

    @objc func sendTab() {
        insert("\t")
    }

    @objc func jumpToPanes() {
        onJumpTo()
    }

    @objc func toggleKeyboard() {
        guard let terminalView else { return }
        if terminalView.isFirstResponder {
            terminalView.resignFirstResponder()
            isKeyboardVisible = false
        } else if terminalView.isInputFocusAllowed {
            // Honor the view model's focus gate: while the pane picker is
            // presented (isInputFocusAllowed == false) the keyboard must
            // not be summoned from the bar.
            terminalView.becomeFirstResponder()
            isKeyboardVisible = true
        }
        refreshKeyboardGlyph()
    }

    /// Glyph state machine: show-keyboard affordance while the keyboard is
    /// hidden, dismiss affordance while it is up. Keyboard notifications
    /// keep the state honest when focus changes outside the bar.
    func installKeyboardGlyphObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardVisibilityDidChange(_:)),
            name: UIApplication.keyboardDidShowNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardVisibilityDidChange(_:)),
            name: UIApplication.keyboardDidHideNotification,
            object: nil
        )
    }

    func refreshKeyboardGlyph() {
        let symbolName = isKeyboardVisible
            ? "keyboard.chevron.compact.down"
            : "keyboard"
        dismissKeyboardButton.setImage(
            UIImage(systemName: symbolName)?
                .applyingSymbolConfiguration(Self.barSymbolConfiguration),
            for: .normal
        )
        dismissKeyboardButton.accessibilityLabel = isKeyboardVisible
            ? "Hide keyboard"
            : "Show keyboard"
    }

    @objc func keyboardVisibilityDidChange(_ notification: Notification) {
        let didShow = notification.name == UIApplication.keyboardDidShowNotification
        // Only the terminal's own keyboard may mark the glyph visible: a
        // keyboard raised elsewhere in the app (e.g. a text field inside
        // the pane picker) must not flip the state while the terminal
        // keyboard is down. Hides always read as "terminal keyboard down"
        // since there is at most one keyboard at a time.
        guard let terminalView else { return }
        if didShow {
            guard terminalView.isFirstResponder else { return }
            isKeyboardVisible = true
        } else {
            isKeyboardVisible = false
        }
        refreshKeyboardGlyph()
    }

    @objc func pasteClipboard() {
        terminalView?.paste(nil)
    }
}
