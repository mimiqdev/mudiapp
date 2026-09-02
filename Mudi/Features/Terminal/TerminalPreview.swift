import SwiftUI

/// A real SwiftTerm surface used by Settings instead of a decorative color
/// swatch. It exercises the same ANSI parser, palette, font, and cursor path
/// as an attached SSH terminal, but has no network session attached.
struct TerminalPreviewView: UIViewRepresentable {
    let theme: TerminalTheme
    let fontFamily: String
    let fontSize: Double

    func makeUIView(context _: Context) -> ShellTerminalView {
        let terminalView = ShellTerminalView(frame: .zero)
        terminalView.apply(theme: theme)
        terminalView.updateFont(
            familyName: fontFamily,
            pointSize: fontSize
        )
        terminalView.feed(text: Self.previewText)
        terminalView.isUserInteractionEnabled = false
        terminalView.accessibilityLabel = "Terminal theme preview"
        return terminalView
    }

    func updateUIView(_ terminalView: ShellTerminalView, context _: Context) {
        terminalView.apply(theme: theme)
        terminalView.updateFont(
            familyName: fontFamily,
            pointSize: fontSize
        )
    }

    static func dismantleUIView(
        _ terminalView: ShellTerminalView,
        coordinator _: ()
    ) {
        terminalView.stop()
    }

    private static let previewText = """
    Mudi terminal preview
    \u{1b}[38;5;196mindexed red\u{1b}[0m  \u{1b}[38;2;52;211;153mtrue color\u{1b}[0m
    \u{1b}[1;38;5;220mbold ANSI\u{1b}[0m  \u{1b}[38;5;39m⌘ Nerd \u{1b}[0m
    """
}
