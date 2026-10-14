import UIKit

@MainActor
extension MudiTerminalShortcutBar {
    func configureAgentActions() {
        agentActionsPanel.onModel = { [weak self] model in
            guard let self, let host = self.terminalView, host.isInputFocusAllowed else { return }
            let context = self.agentActionsState.context
            let session = host.session.map(ObjectIdentifier.init)
            host.sendComposedText(model.command, bracketedPaste: true, appendReturn: false)
            self.dismissAgentActions()
            Task { @MainActor [weak self, weak host] in
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, let host, self.terminalView === host, host.isInputFocusAllowed,
                      host.session.map(ObjectIdentifier.init) == session, self.agentActionsState.context == context else { return }
                host.send([13])
                self.agentActionsPanel.lastSentModel = model.command
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                let toast = UILabel()
                toast.text = "已发送 " + model.command
                toast.font = .systemFont(ofSize: 12)
                toast.textColor = .label
                toast.backgroundColor = .secondarySystemBackground
                toast.layer.cornerRadius = 8
                toast.clipsToBounds = true
                if let container = self.superview {
                    toast.frame = CGRect(x: 16, y: max(0, self.frame.minY - 50), width: container.bounds.width - 32, height: 34)
                    container.addSubview(toast)
                    Task { @MainActor in try? await Task.sleep(for: .milliseconds(1500)); toast.removeFromSuperview() }
                }
            }
        }
        agentActionsPanel.onAction = { [weak self] id in self?.performAgentAction(id) }
        agentActionsPanel.onPreset = { [weak self] preset in
            guard let self, self.terminalView?.isInputFocusAllowed == true else { return }
            self.agentActionsState.selectPreset(preset)
            self.agentActionsPanel.render(self.agentActionsState)
        }
        agentActionsPanel.onConfirm = { [weak self] in self?.confirmAgentCommand() }
        agentActionsPanel.onCancel = { [weak self] in
            guard let self else { return }
            self.agentActionsState.cancelCommand()
            self.agentActionsPanel.render(self.agentActionsState)
        }
        agentActionsPanel.onClose = { [weak self] in self?.dismissAgentActions() }
    }

    func updateAgentActionsContext(_ context: TerminalAgentActionsContext?) {
        agentActionsState.updateContext(context)
        agentActionsPanel.render(agentActionsState)
    }

    @objc func toggleAgentActions() {
        guard terminalView?.isInputFocusAllowed == true, !isShowingComposition else { return }
        if activePopup == .agentActions {
            dismissAgentActions()
        } else {
            agentActionsState.cancelCommand()
            agentActionsPanel.render(agentActionsState)
            activePopup = .agentActions
            clearModifiers()
        }
    }

    func dismissAgentActions() {
        agentActionsState.cancelCommand()
        if activePopup == .agentActions { activePopup = .none }
        agentActionsPanel.render(agentActionsState)
        applyPopupState()
    }

    private func performAgentAction(_ id: String) {
        guard activePopup == .agentActions,
              terminalView?.isInputFocusAllowed == true
        else { return }
        let bytes = agentActionsState.selectAction(id)
        agentActionsPanel.render(agentActionsState)
        if let bytes {
            send(bytes)
            dismissAgentActions()
        }
    }

    private func confirmAgentCommand() {
        guard activePopup == .agentActions,
              terminalView?.isInputFocusAllowed == true,
              let bytes = agentActionsState.confirmCommand()
        else { return }
        agentActionsPanel.render(agentActionsState)
        guard let host = terminalView else { return }
        let context = agentActionsState.context
        let session = host.session.map(ObjectIdentifier.init)
        // Submit separately: TUI parsers can treat text + CR in one read as
        // pasted text rather than an Enter key event.
        host.sendComposedText(String(decoding: bytes.dropLast(), as: UTF8.self), bracketedPaste: true, appendReturn: false)
        clearModifiers()
        dismissAgentActions()
        Task { @MainActor [weak self, weak host] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, let host, self.terminalView === host,
                  host.isInputFocusAllowed, host.session.map(ObjectIdentifier.init) == session, self.agentActionsState.context == context else { return }
            host.send([0x0d])
        }
    }
}
