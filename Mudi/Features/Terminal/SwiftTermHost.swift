import HerdrKit
@preconcurrency import SwiftTerm
import UIKit

@MainActor
extension ShellTerminalView: TerminalHost {
    var hostView: UIView { self }

    func sendCursorKey(normal: [UInt8], application: [UInt8], final: UInt8) {
        if controlModifier || metaModifier {
            let modifier: UInt8 = controlModifier ? (metaModifier ? 0x37 : 0x35) : 0x33
            send([0x1b, 0x5b, 0x31, 0x3b, modifier, final])
            controlModifier = false
            metaModifier = false
            shortcutBar?.updateModifierState()
        } else {
            send(getTerminal().applicationCursor ? application : normal)
        }
    }

    func sendComposedText(_ text: String, bracketedPaste: Bool, appendReturn: Bool) {
        guard !text.isEmpty else { return }
        let bracket = bracketedPaste && getTerminal().bracketedPasteMode
        let payload = (bracket ? "\u{1b}[200~\(text)\u{1b}[201~" : text) + (appendReturn ? "\r" : "")
        send(Array(payload.utf8))
    }
}
