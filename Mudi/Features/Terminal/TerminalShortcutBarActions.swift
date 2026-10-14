import UIKit
@preconcurrency import SwiftTerm

final class MudiPopupDismissTapGestureRecognizer: UITapGestureRecognizer {
    weak var shortcutBar: MudiTerminalShortcutBar?

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}

/// Key dispatch and latch/state rendering for MudiTerminalShortcutBar:
/// byte-sequence sending, arrow/application-cursor handling, modifier
/// latching (with the combo popup visibility) and the chip styling used
/// for latched states.
@MainActor
extension MudiTerminalShortcutBar {
    @objc func modifierDidReset(_: Notification) {
        updateModifierState()
    }

    func style(_ button: UIButton?) {
        guard let button else { return }
        let cap = (button as? MudiKeyButton)?.cap ?? button
        cap.backgroundColor = button.isSelected ? MudiPalette.inkUI : normalBackgroundColor.withAlphaComponent(0.5)
        button.tintColor = button.isSelected ? MudiPalette.canvasUI : foregroundColor
        button.setTitleColor(button.tintColor, for: .normal)
        cap.layer.cornerRadius = 17
        cap.layer.borderWidth = 0
        cap.layer.borderColor = MudiPalette.borderUI.resolvedColor(with: traitCollection).cgColor
        button.accessibilityTraits = button.isSelected ? [.button, .selected] : [.button]
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

    func dismissAllPopups() {
        activePopup = .none
        agentActionsState.cancelCommand()
        applyPopupState()
    }

    /// Pane switches and input suspension retire the latches too; plain
    /// popup dismissal (outside taps, keyboard raise) keeps them so the
    /// Ctrl-latch → terminal-tap → letter flow survives.
    func dismissAllPopupsAndClearModifiers() {
        dismissAllPopups()
        clearModifiers()
    }

    /// Long-press on the Ctrl cap: switch to the single-shot Alt latch.
    /// Tapping Ctrl again cancels it (see toggleControl).
    @objc func handleControlLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        toggleAltLatch()
    }

    /// Switches between the single-shot Alt latch and no latch. Tapping the
    /// Ctrl cap while Alt is latched cancels it (see toggleControl).
    func toggleAltLatch() {
        guard let terminalView, !isShowingComposition else { return }
        if terminalView.metaModifier {
            terminalView.metaModifier = false
        } else {
            terminalView.controlModifier = false
            activePopup = .none
            terminalView.metaModifier = true
        }
        applyPopupState()
    }

    func installPopupDismissGesture(on container: UIView) {
        guard !(container.gestureRecognizers ?? []).contains(where: { ($0 as? MudiPopupDismissTapGestureRecognizer)?.shortcutBar === self }) else { return }
        let tap = MudiPopupDismissTapGestureRecognizer(target: self, action: #selector(dismissPopupsFromTerminalTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        tap.shortcutBar = self
        container.addGestureRecognizer(tap)
    }

    func dismissPopupIfOutsideTap(at point: CGPoint, in container: UIView) {
        container.layoutIfNeeded()
        var interiorViews: [UIView] = [comboPopup, dpadOverlay, agentActionsPanel]
        if let barSuperview = superview, barSuperview === container { interiorViews.append(self) }
        let hitPopup = interiorViews.contains { view in
            guard !view.isHidden else { return false }
            return view.bounds.contains(container.convert(point, to: view))
        }
        guard !hitPopup else { return }
        dismissAllPopups()
    }

    @objc private func dismissPopupsFromTerminalTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, let container = recognizer.view else { return }
        dismissPopupIfOutsideTap(at: recognizer.location(in: container), in: container)
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
        terminalView.sendCursorKey(normal: normal, application: application, final: final)
        updateModifierState()
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
        case .backspace:
            send([0x7f])
        case .clearScreen:
            send([0x0c])
        case .home:
            send([0x1b, 0x5b, 0x48])
        case .end:
            send([0x1b, 0x5b, 0x46])
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
        comboPopup.isHidden = true
        dpadOverlay.isHidden = activePopup != .dPad
        agentActionsPanel.isHidden = activePopup != .agentActions
        if activePopup != .agentActions {
            agentActionsState.cancelCommand()
            agentActionsPanel.render(agentActionsState)
        }
        agentActionsButton?.isSelected = activePopup == .agentActions
        style(agentActionsButton)
        controlButton?.setTitle(terminalView?.metaModifier == true ? "Alt" : "Ctrl", for: .normal)
        controlButton?.isSelected = ctrlLatched || terminalView?.metaModifier == true
        dpadButton?.isSelected = activePopup == .dPad
        style(controlButton)
        style(dpadButton)
        synchronizeModifierKeyboard()
        setNeedsLayout()
        layoutIfNeeded()
        if superview != nil { terminalView?.updateShortcutBarOffset() }
    }

    @objc func toggleControl() {
        guard let terminalView, !isShowingComposition else { return }
        // While the Alt latch is on, tapping the cap cancels it instead of
        // latching Ctrl (the agreed interaction).
        if terminalView.metaModifier {
            terminalView.metaModifier = false
            applyPopupState()
            return
        }
        terminalView.controlModifier.toggle()
        if terminalView.controlModifier {
            // Opening the popup replaces whichever popup was open.
            activePopup = .none
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
            if dpadRelativePosition == nil { anchorDPadNearDirectionButton() }
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
        if let composer, !composer.isHidden {
            if composer.input.isFirstResponder { composer.input.resignFirstResponder() }
            else if terminalView.isInputFocusAllowed { composer.input.becomeFirstResponder() }
            return
        }
        if isModifierInputActive {
            clearModifiers()
            terminalView.resignFirstResponder()
            isKeyboardVisible = false
        } else if terminalView.isFirstResponder {
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
        dismissKeyboardButton.setImage((isKeyboardVisible ? MudiIcon.keyboardHide : .keyboard).uiImage, for: .normal)
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
            guard terminalView.isFirstResponder || isModifierInputActive else { return }
            isKeyboardVisible = true
            dismissAllPopups()
        } else {
            isKeyboardVisible = false
        }
        refreshKeyboardGlyph()
    }

    @objc func pasteClipboard() {
        terminalView?.paste(nil)
    }
}
