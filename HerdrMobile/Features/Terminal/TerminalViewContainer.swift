import SwiftTerm
import SwiftUI

struct TerminalViewContainer: UIViewRepresentable {
    func makeUIView(context: Context) -> TerminalView {
        TerminalView(frame: .zero)
    }

    func updateUIView(_ terminalView: TerminalView, context: Context) {}
}
