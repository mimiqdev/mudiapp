import UIKit

@MainActor
extension MudiTerminalShortcutBar {
    @objc func reverseTab(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        send([0x1b, 0x5b, 0x5a])
    }
    @objc func recallHistory() { handle(.cursorUp) }
    func sendComposedText(_ text: String, bracketedPaste: Bool = true, appendReturn: Bool = false) {
        guard !text.isEmpty else { return }
        let bracket = bracketedPaste && terminalView?.getTerminal().bracketedPasteMode == true
        let payload = (bracket ? "\u{1b}[200~\(text)\u{1b}[201~" : text) + (appendReturn ? "\r" : "")
        send(Array(payload.utf8))
    }
    @objc func openCompose() {
        guard let terminalView, terminalView.isInputFocusAllowed else { return }
        if composer?.isHidden == false { composer?.input.becomeFirstResponder(); return }
        composeRestoresTerminalFocus = terminalView.isFirstResponder
        if composer == nil {
            let card = MudiComposerCard(bar: self)
            card.translatesAutoresizingMaskIntoConstraints = false
            addSubview(card)
            NSLayoutConstraint.activate([
                card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                card.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
            ])
            composer = card
        }
        activePopup = .none; clearModifiers()
        composer?.isHidden = false
        composer?.prepareForOpening(target: composeTargetLabel)
        setComposerChromeVisible(true)
        composer?.input.becomeFirstResponder()
    }
    func closeCompose() {
        composer?.input.resignFirstResponder()
        composer?.isHidden = true
        setComposerChromeVisible(false)
        if composeRestoresTerminalFocus, terminalView?.isInputFocusAllowed == true {
            terminalView?.becomeFirstResponder()
        }
    }
    private func setComposerChromeVisible(_ visible: Bool) {
        scrollView.isHidden = visible; pinnedStackView.isHidden = visible
        dividerView.isHidden = visible; compositionLabel.isHidden = true
        updateBackdropForComposer(visible)
        invalidateIntrinsicContentSize()
        terminalView?.updateShortcutBarOffset()
        setNeedsLayout()
    }
}
