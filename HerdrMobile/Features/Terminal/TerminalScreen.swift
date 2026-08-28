import SwiftUI

struct TerminalScreen: View {
    let paneID: String

    var body: some View {
        VStack(spacing: 0) {
            TerminalViewContainer()
            TerminalShortcutBar()
        }
        .background(.black)
        .navigationTitle("Terminal")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct TerminalShortcutBar: View {
    private let keys = ["Esc", "Ctrl", "Alt", "Tab", "←", "↓", "↑", "→"]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(keys, id: \.self) { key in
                    Button(key) {}
                        .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }
}
