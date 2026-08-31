import HerdrKit
import SwiftUI

struct TerminalScreen: View {
    let host: Host
    let session: SSHShellSession
    let title: String
    let transport: ActiveTransport
    let onDisconnect: () -> Void
    let onBackToBrowser: (() -> Void)?
    let fontSize: Double
    let suppressConnectionErrors: Bool

    @Environment(\.colorScheme) private var colorScheme
    @State private var errorMessage: String?

    init(
        host: Host,
        session: SSHShellSession,
        title: String? = nil,
        transport: ActiveTransport = .ssh,
        onDisconnect: @escaping () -> Void,
        onBackToBrowser: (() -> Void)? = nil,
        fontSize: Double = 14,
        suppressConnectionErrors: Bool = false
    ) {
        self.host = host
        self.session = session
        self.title = title ?? host.hostname
        self.transport = transport
        self.onDisconnect = onDisconnect
        self.onBackToBrowser = onBackToBrowser
        self.fontSize = fontSize
        self.suppressConnectionErrors = suppressConnectionErrors
    }

    var body: some View {
        ZStack(alignment: .top) {
            TerminalViewContainer(
                session: session,
                fontSize: fontSize,
                colorScheme: colorScheme
            ) { message in
                guard !suppressConnectionErrors else { return }
                errorMessage = message
            }
            .background(Color(uiColor: terminalAppearance.background))

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
        .background(Color(uiColor: terminalAppearance.background))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Label(transport.displayName, systemImage: transport.systemImage)
                    .accessibilityIdentifier("active-transport")
            }
            if let onBackToBrowser {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Herdr", systemImage: "chevron.backward", action: onBackToBrowser)
                        .tint(Color(uiColor: terminalAppearance.foreground))
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Disconnect", systemImage: "xmark.circle") {
                    onDisconnect()
                }
                .tint(Color(uiColor: terminalAppearance.foreground))
            }
        }
    }

    private var terminalAppearance: TerminalAppearance {
        TerminalAppearance.colors(for: colorScheme)
    }
}

private extension ActiveTransport {
    var displayName: String {
        switch self {
        case .mosh:
            "Mosh"
        case .ssh:
            "SSH"
        }
    }

    var systemImage: String {
        switch self {
        case .mosh:
            "antenna.radiowaves.left.and.right"
        case .ssh:
            "network"
        }
    }
}
