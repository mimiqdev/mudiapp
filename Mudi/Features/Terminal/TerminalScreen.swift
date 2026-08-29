import HerdrKit
import SwiftUI

struct TerminalScreen: View {
    let host: Host
    let session: SSHShellSession
    let onDisconnect: () -> Void

    @State private var errorMessage: String?

    var body: some View {
        ZStack(alignment: .top) {
            TerminalViewContainer(session: session) { message in
                errorMessage = message
            }
            .background(.black)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.red.opacity(0.9), in: Capsule())
                    .padding(.top, 10)
                    .padding(.horizontal, 12)
                    .accessibilityIdentifier("ssh-terminal-error")
            }
        }
        .background(.black)
        .navigationTitle(host.hostname)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Disconnect", systemImage: "xmark.circle") {
                    onDisconnect()
                }
                .tint(.white)
            }
        }
    }
}
