import HerdrKit
import SwiftUI

struct TerminalScreen: View {
    let host: Host
    let session: SSHShellSession
    let onDisconnect: () -> Void
    let onBackToBrowser: (() -> Void)?

    @State private var errorMessage: String?

    init(
        host: Host,
        session: SSHShellSession,
        onDisconnect: @escaping () -> Void,
        onBackToBrowser: (() -> Void)? = nil
    ) {
        self.host = host
        self.session = session
        self.onDisconnect = onDisconnect
        self.onBackToBrowser = onBackToBrowser
    }

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
            if let onBackToBrowser {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Herdr", systemImage: "chevron.backward", action: onBackToBrowser)
                        .tint(.white)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Disconnect", systemImage: "xmark.circle") {
                    onDisconnect()
                }
                .tint(.white)
            }
        }
    }
}
