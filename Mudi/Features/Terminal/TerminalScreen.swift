import HerdrKit
import SwiftUI

struct TerminalSessionErrorState: Equatable {
    private(set) var sessionIdentity: ObjectIdentifier
    private(set) var message: String?

    init(sessionIdentity: ObjectIdentifier, message: String? = nil) {
        self.sessionIdentity = sessionIdentity
        self.message = message
    }

    mutating func updateSession(_ sessionIdentity: ObjectIdentifier) {
        guard self.sessionIdentity != sessionIdentity else { return }
        self.sessionIdentity = sessionIdentity
        message = nil
    }

    mutating func receive(
        _ message: String,
        for sessionIdentity: ObjectIdentifier
    ) {
        guard self.sessionIdentity == sessionIdentity else { return }
        self.message = message
    }

    mutating func clear() {
        message = nil
    }
}

struct TerminalScreen: View {
    let host: Host
    let session: SSHShellSession
    let title: String
    let transport: ActiveTransport
    let onDisconnect: () -> Void
    let onBackToBrowser: (() -> Void)?
    let onOpenPanePicker: (() -> Void)?
    let onSessionClosed: ((ObjectIdentifier) -> Void)?
    let fontSize: Double
    let isInputFocusAllowed: Bool
    let shouldRestoreInputFocus: Bool
    let onInputFocusChange: ((Bool) -> Void)?
    let suppressConnectionErrors: Bool

    @Environment(\.colorScheme) private var colorScheme
    @State private var terminalErrorState: TerminalSessionErrorState
    @State private var isLeaving = false

    init(
        host: Host,
        session: SSHShellSession,
        title: String? = nil,
        transport: ActiveTransport = .ssh,
        onDisconnect: @escaping () -> Void,
        onBackToBrowser: (() -> Void)? = nil,
        onOpenPanePicker: (() -> Void)? = nil,
        onSessionClosed: ((ObjectIdentifier) -> Void)? = nil,
        fontSize: Double = 14,
        isInputFocusAllowed: Bool = true,
        shouldRestoreInputFocus: Bool = false,
        onInputFocusChange: ((Bool) -> Void)? = nil,
        suppressConnectionErrors: Bool = false
    ) {
        self.host = host
        self.session = session
        self.title = title ?? host.hostname
        self.transport = transport
        self.onDisconnect = onDisconnect
        self.onBackToBrowser = onBackToBrowser
        self.onOpenPanePicker = onOpenPanePicker
        self.onSessionClosed = onSessionClosed
        _terminalErrorState = State(
            initialValue: TerminalSessionErrorState(
                sessionIdentity: ObjectIdentifier(session)
            )
        )
        self.fontSize = fontSize
        self.isInputFocusAllowed = isInputFocusAllowed
        self.shouldRestoreInputFocus = shouldRestoreInputFocus
        self.onInputFocusChange = onInputFocusChange
        self.suppressConnectionErrors = suppressConnectionErrors
    }

    var body: some View {
        ZStack(alignment: .top) {
            TerminalViewContainer(
                session: session,
                fontSize: fontSize,
                colorScheme: colorScheme,
                isInputFocusAllowed: isInputFocusAllowed,
                shouldRestoreInputFocus: shouldRestoreInputFocus,
                onInputFocusChange: onInputFocusChange,
                onClosed: {
                    guard !isLeaving else { return }
                    terminalErrorState.clear()
                    onSessionClosed?(ObjectIdentifier(session))
                },
                onError: { message in
                    guard !suppressConnectionErrors, !isLeaving else { return }
                    terminalErrorState.receive(
                        message,
                        for: ObjectIdentifier(session)
                    )
                }
            )
            .background(Color(uiColor: terminalAppearance.background))

            if let errorMessage = terminalErrorState.message {
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
        .onAppear {
            isLeaving = false
            terminalErrorState.clear()
        }
        .onChange(of: ObjectIdentifier(session)) { _, newIdentity in
            isLeaving = false
            terminalErrorState.updateSession(newIdentity)
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
            if let onOpenPanePicker {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Switch Pane", systemImage: "rectangle.stack") {
                        terminalErrorState.clear()
                        onOpenPanePicker()
                    }
                    .accessibilityIdentifier("open-pane-picker")
                    .tint(Color(uiColor: terminalAppearance.foreground))
                }
            } else if let onBackToBrowser {
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
        terminalErrorState.clear()
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
