import HerdrKit
import SwiftUI
import UIKit

/// The transport badge is deliberately kept in a surface corner below the
/// navigation bar, rather than in the toolbar or the bottom shortcut-bar
/// strip. This keeps it visible without competing with either system chrome.
enum TerminalTransportBadgeCorner: Equatable {
    case topTrailing
}

struct TerminalTransportBadgePlacementPolicy: Equatable {
    let corner: TerminalTransportBadgeCorner
    let horizontalInset: CGFloat
    let topInset: CGFloat

    static let phone = Self(
        corner: .topTrailing,
        horizontalInset: 12,
        topInset: 8
    )
    static let pad = Self(
        corner: .topTrailing,
        horizontalInset: 20,
        topInset: 12
    )

    static func resolved(for idiom: UIUserInterfaceIdiom) -> Self {
        idiom == .pad ? .pad : .phone
    }

    var alignment: Alignment {
        switch corner {
        case .topTrailing:
            .topTrailing
        }
    }
}

/// Solid info-semantic colors for the transport badge. ANSI 4 is the
/// theme's normal blue anchor; the text uses whichever of the theme's
/// foreground/background anchors has the greater relative-luminance contrast.
struct TerminalTransportBadgeStyle: Equatable {
    let fill: TerminalRGBColor
    let text: TerminalRGBColor

    static func resolved(for theme: TerminalTheme) -> Self {
        let fill = theme.ansi16.count > 4
            ? theme.ansi16[4]
            : theme.defaultForeground
        let candidates = [theme.defaultForeground, theme.defaultBackground]
        let text = candidates.max {
            contrastRatio(between: $0, and: fill)
                < contrastRatio(between: $1, and: fill)
        } ?? theme.defaultForeground
        return Self(fill: fill, text: text)
    }

    var contrastRatio: Double {
        Self.contrastRatio(between: text, and: fill)
    }

    static func contrastRatio(
        between lhs: TerminalRGBColor,
        and rhs: TerminalRGBColor
    ) -> Double {
        let lhsLuminance = relativeLuminance(lhs)
        let rhsLuminance = relativeLuminance(rhs)
        let lighter = max(lhsLuminance, rhsLuminance)
        let darker = min(lhsLuminance, rhsLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func relativeLuminance(_ color: TerminalRGBColor) -> Double {
        0.2126 * luminanceComponent(color.red)
            + 0.7152 * luminanceComponent(color.green)
            + 0.0722 * luminanceComponent(color.blue)
    }

    private static func luminanceComponent(_ value: UInt8) -> Double {
        let normalized = Double(value) / 255
        if normalized <= 0.03928 {
            return normalized / 12.92
        }
        return pow((normalized + 0.055) / 1.055, 2.4)
    }
}

/// Horizontal breathing room between the terminal grid and the bezels.
/// The terminal view's width shrinks by the inset, so column counts are
/// computed from the inset bounds (resize accounting stays correct).
struct TerminalHorizontalInsetPolicy: Equatable {
    let horizontalInset: CGFloat
    static let standard = Self(horizontalInset: 6)
}

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

@MainActor
struct TerminalScreen: View {
    let host: Host
    let session: SSHShellSession
    let title: String
    let subtitle: String?
    let transport: ActiveTransport
    let onDisconnect: () -> Void
    let onBackToBrowser: (() -> Void)?
    let onOpenPanePicker: (() -> Void)?
    let onSessionClosed: ((ObjectIdentifier) -> Void)?
    let onBackToHosts: (() -> Void)?
    @ObservedObject var settingsModel: RootViewModel
    let themeSelection: TerminalThemeSelection
    let fontFamily: String
    let fontSize: Double
    let isInputFocusAllowed: Bool
    let shouldRestoreInputFocus: Bool
    let onInputFocusChange: ((Bool) -> Void)?
    let suppressConnectionErrors: Bool

    @Environment(\.colorScheme) private var colorScheme
    @State private var terminalErrorState: TerminalSessionErrorState
    @State private var isLeaving = false
    @State private var isTerminalSettingsPresented = false

    init(
        host: Host,
        session: SSHShellSession,
        title: String? = nil,
        subtitle: String? = nil,
        transport: ActiveTransport = .ssh,
        onDisconnect: @escaping () -> Void,
        onBackToBrowser: (() -> Void)? = nil,
        onOpenPanePicker: (() -> Void)? = nil,
        onSessionClosed: ((ObjectIdentifier) -> Void)? = nil,
        onBackToHosts: (() -> Void)? = nil,
        settingsModel: RootViewModel? = nil,
        themeSelection: TerminalThemeSelection = TerminalThemeRegistry.defaultSelection,
        fontFamily: String = TerminalFontRegistry.defaultFamilyName,
        fontSize: Double = 14,
        isInputFocusAllowed: Bool = true,
        shouldRestoreInputFocus: Bool = false,
        onInputFocusChange: ((Bool) -> Void)? = nil,
        suppressConnectionErrors: Bool = false
    ) {
        self.host = host
        self.session = session
        self.title = title ?? host.displayName
        self.subtitle = subtitle
        self.transport = transport
        self.onDisconnect = onDisconnect
        self.onBackToBrowser = onBackToBrowser
        self.onOpenPanePicker = onOpenPanePicker
        self.onSessionClosed = onSessionClosed
        self.onBackToHosts = onBackToHosts
        let resolvedSettingsModel = settingsModel ?? RootViewModel()
        if settingsModel == nil {
            resolvedSettingsModel.preferences.themeSelection = themeSelection
            resolvedSettingsModel.preferences.fontFamily = fontFamily
            resolvedSettingsModel.preferences.fontSize = fontSize
        }
        _settingsModel = ObservedObject(
            wrappedValue: resolvedSettingsModel
        )
        self.themeSelection = themeSelection
        self.fontFamily = fontFamily
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
                fontSize: currentFontSize,
                fontFamily: currentFontFamily,
                theme: terminalAppearance.theme,
                colorScheme: colorScheme,
                isInputFocusAllowed: isInputFocusAllowed,
                shouldRestoreInputFocus: shouldRestoreInputFocus,
                onInputFocusChange: onInputFocusChange,
                thumbArcPreferences: settingsModel.preferences.thumbArc,
                onOpenPanePicker: onOpenPanePicker,
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
            .padding(
                .horizontal,
                TerminalHorizontalInsetPolicy.standard.horizontalInset
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

            if let onBackToHosts {
                AccessibilityIdentifierBridge(
                    identifier: "return-to-hosts",
                    action: { beginLeaving(onBackToHosts) }
                )
                .frame(width: 1, height: 1)
            }

            // SwiftUI toolbar/text identifiers are not guaranteed to
            // materialize as UIKit views for automation. These inert bridges
            // keep the surface and sheet contracts discoverable without
            // duplicating any state or visible controls.
            AccessibilityIdentifierBridge(
                identifier: "terminal-transport-badge",
                accessibilityLabel: transport.accessibilityLabel
            )
            .frame(width: 1, height: 1)
            AccessibilityIdentifierBridge(
                identifier: "terminal-settings",
                action: { isTerminalSettingsPresented = true }
            )
            .frame(width: 1, height: 1)

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
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                HStack(spacing: 10) {
                    if let onBackToHosts {
                        MudiRoundButton(icon: .chevronLeft, label: "Hosts", action: { beginLeaving(onBackToHosts) })
                            .accessibilityIdentifier("return-to-hosts")
                    } else if let onBackToBrowser {
                        MudiRoundButton(icon: .chevronLeft, label: "Herdr", action: { beginLeaving(onBackToBrowser) })
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(MudiTypography.body(16, weight: .semibold)).lineLimit(1)
                            .foregroundStyle(MudiPalette.ink)
                        Text(subtitle ?? (host.displayName + " · " + (host.selectedTarget?.address ?? host.hostname)))
                            .font(MudiTypography.mono(11)).foregroundStyle(MudiPalette.mute).lineLimit(1)
                    }.frame(width: 180, alignment: .leading)
                }.fixedSize(horizontal: true, vertical: false)
            }.mudiToolbarBackground()
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 8) {
                    transportBadge.fixedSize()
                    MudiRoundButton(icon: .settings, label: "终端设置", action: { isTerminalSettingsPresented = true })
                        .accessibilityIdentifier("terminal-settings")
                }.fixedSize()
            }.mudiToolbarBackground()
        }
        .sheet(isPresented: $isTerminalSettingsPresented) {
            NavigationStack {
                TerminalAppearanceSettingsView(model: settingsModel)
            }
            .preferredColorScheme(settingsModel.preferences.appearance.colorScheme)
            .background(
                InterfaceStyleOverride(
                    colorScheme: settingsModel.preferences.appearance.colorScheme
                )
            )
        }
    }

    private func beginLeaving(_ action: () -> Void) {
        isLeaving = true
        terminalErrorState.clear()
        action()
    }

    private var terminalAppearance: TerminalAppearance {
        let variant: TerminalThemeVariant = colorScheme == .dark ? .dark : .light
        let theme = TerminalThemeRegistry.resolve(
            currentThemeSelection,
            for: variant
        ) ?? TerminalAppearance.colors(for: colorScheme).theme
        return TerminalAppearance(theme: theme)
    }

    private var currentThemeSelection: TerminalThemeSelection {
        settingsModel.preferences.themeSelection
    }

    private var currentFontFamily: String {
        settingsModel.preferences.fontFamily
    }

    private var currentFontSize: Double {
        settingsModel.preferences.fontSize
    }

    private var terminalTransportBadgePolicy: TerminalTransportBadgePlacementPolicy {
        TerminalTransportBadgePlacementPolicy.resolved(
            for: UIDevice.current.userInterfaceIdiom
        )
    }

    private var transportBadgeStyle: TerminalTransportBadgeStyle {
        .resolved(for: terminalAppearance.theme)
    }

    private var transportBadge: some View {
        Text(transport.displayName)
            .font(MudiTypography.mono(11))
            .foregroundStyle(MudiPalette.mute)
            .padding(.horizontal, 9).frame(height: 24)
            .overlay(Capsule().stroke(MudiPalette.border, lineWidth: 1))
            .accessibilityLabel(transport.accessibilityLabel)
            .accessibilityIdentifier("terminal-transport-badge")
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

    var accessibilityLabel: String {
        "Active transport: \(displayName)"
    }
}
