import SwiftUI
import UIKit

@MainActor
extension MudiTerminalShortcutBar {
    @objc func reverseTab(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        send([0x1b, 0x5b, 0x5a])
    }
    @objc func recallHistory() { handle(.cursorUp) }
    func sendComposedText(_ text: String) {
        guard !text.isEmpty else { return }
        let payload = terminalView?.getTerminal().bracketedPasteMode == true
            ? "\u{1b}[200~\(text)\u{1b}[201~" : text
        send(Array(payload.utf8))
    }
    @objc func openCompose() {
        guard let terminalView, terminalView.isInputFocusAllowed,
              var presenter = window?.rootViewController else { return }
        while let presented = presenter.presentedViewController { presenter = presented }
        let restoreFocus = terminalView.isFirstResponder
        _ = terminalView.resignFirstResponder()
        let controller = UIHostingController(rootView: MudiComposeView(onSend: { [weak self] text in
            self?.sendComposedText(text)
        }, onDismiss: { [weak terminalView] in
            guard restoreFocus, let terminalView, terminalView.isInputFocusAllowed else { return }
            _ = terminalView.becomeFirstResponder()
        }))
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        presenter.present(controller, animated: true)
    }
}

struct MudiComposeView: View {
    let onSend: (String) -> Void
    var onDismiss: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(MudiTypography.body()).foregroundStyle(MudiPalette.ink)
                .scrollContentBackground(.hidden)
                .padding(16).background(MudiPalette.canvas)
                .focused($focused).accessibilityIdentifier("terminal-compose-input")
                .navigationTitle("Compose").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("发送") { onSend(text); dismiss() }
                            .buttonStyle(MudiPillStyle(filled: true)).disabled(text.isEmpty)
                            .accessibilityIdentifier("terminal-compose-send")
                    }
                }
                .onAppear { focused = true }
        }.tint(MudiPalette.ink).onDisappear(perform: onDismiss)
    }
}
