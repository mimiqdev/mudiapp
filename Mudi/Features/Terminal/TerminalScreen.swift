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
    @State private var compositionText: String?
    @State private var isLeaving = false

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
                colorScheme: colorScheme,
                onError: { message in
                    guard !suppressConnectionErrors, !isLeaving else { return }
                    errorMessage = message
                },
                onCompositionChange: { markedText in
                    compositionText = markedText
                }
            )
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

            if let compositionText {
                Text(compositionText)
                    .font(.system(size: CGFloat(max(fontSize, 12)), design: .monospaced))
                    .foregroundStyle(Color(uiColor: terminalAppearance.foreground))
                    .underline()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        Color(uiColor: terminalAppearance.background).opacity(0.96),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("terminal-ime-composition")
                    .accessibilityLabel("Composing \(compositionText)")
            }
        }
        .background(Color(uiColor: terminalAppearance.background))
        .onAppear {
            isLeaving = false
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Label {
                    Text(transport.displayName)
                } icon: {
                    Image(systemName: transport.systemImage)
                }
                .labelStyle(.titleAndIcon)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(transport.accessibilityLabel)
                .accessibilityIdentifier("active-transport")
            }
            if let onBackToBrowser {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Herdr", systemImage: "chevron.backward") {
                        beginLeaving {
                            onBackToBrowser()
                        }
                    }
                    .tint(Color(uiColor: terminalAppearance.foreground))
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Disconnect", systemImage: "xmark.circle") {
                    beginLeaving(onDisconnect)
                }
                .tint(Color(uiColor: terminalAppearance.foreground))
            }
        }
    }

    private func beginLeaving(_ action: () -> Void) {
        isLeaving = true
        errorMessage = nil
        action()
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

    var accessibilityLabel: String {
        "Active transport: \(displayName)"
    }
}
