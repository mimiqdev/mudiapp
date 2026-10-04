import CoreText
import SwiftUI
import UIKit

/// Tokens from Figma's Mudi Color collection. Terminal palettes remain independent.
@MainActor
enum MudiPalette {
    static var canvas: Color { Color(uiColor: canvasUI) }
    static var surface: Color { Color(uiColor: surfaceUI) }
    static var raised: Color { Color(uiColor: raisedUI) }
    static var sheet: Color { Color(uiColor: sheetUI) }
    static var ink: Color { Color(uiColor: inkUI) }
    static var body: Color { Color(uiColor: adaptive(0xDADBDF, 0x3A3C40)) }
    static var mute: Color { Color(uiColor: muteUI) }
    static var dim: Color { Color(uiColor: adaptive(0x4B4F55, 0x8A8E94)) }
    static var hairline: Color { Color(uiColor: hairlineUI) }
    static var border: Color { Color(uiColor: borderUI) }
    static var sunset: Color { Color(uiColor: sunsetUI) }
    static var green: Color { Color(uiColor: adaptive(0x3FB950, 0x17803B)) }
    static var red: Color { Color(uiColor: adaptive(0xF0524F, 0xC4281C)) }
    static var canvasUI: UIColor { adaptive(0x0A0A0A, 0xFAFAF7) }
    static var surfaceUI: UIColor { adaptive(0x191919, 0xFFFFFF) }
    static var raisedUI: UIColor { adaptive(0x26282C, 0xFFFFFF) }
    static var sheetUI: UIColor { adaptive(0x111113, 0xF2F2EE) }
    static var keyUI: UIColor { adaptive(0x1A1C20, 0xFFFFFF) }
    static var inkUI: UIColor { adaptive(0xFFFFFF, 0x0A0A0A) }
    static var muteUI: UIColor { adaptive(0x7D8187, 0x676B71) }
    static var hairlineUI: UIColor { adaptive(0x212327, 0xE6E6E1) }
    static var borderUI: UIColor { adaptive(0x2E3136, 0xD6D6D0) }
    static var sunsetUI: UIColor { adaptive(0xFF7A17, 0xC24A00) }
    static var glassLineUI: UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.22) : UIColor(white: 0.04, alpha: 0.10) }
    }
    static var glassTintUI: UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? adaptive(0x26282C, 0xFFFFFF).resolvedColor(with: $0).withAlphaComponent(0.20) : UIColor.white.withAlphaComponent(0.10) }
    }
    static func glassShadowOpacity(in traits: UITraitCollection) -> Float { traits.userInterfaceStyle == .dark ? 0.45 : 0.14 }

    nonisolated static func adaptive(_ dark: UInt32, _ light: UInt32) -> UIColor {
        UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 255) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        }
    }
}

@MainActor
enum MudiTypography {
    private static var registered = false
    static func registerFonts() {
        guard !registered else { return }
        registered = true
        for name in ["Inter", "NotoSansSC"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "ttf") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = MudiPalette.canvasUI
        appearance.shadowColor = .clear
        appearance.titleTextAttributes = [.font: uiFont(17, weight: .semibold), .foregroundColor: MudiPalette.inkUI]
        appearance.largeTitleTextAttributes = [.font: uiFont(34, weight: .bold), .foregroundColor: MudiPalette.inkUI]
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
        UISegmentedControl.appearance().selectedSegmentTintColor = MudiPalette.raisedUI
    }

    static func uiFont(_ size: CGFloat, weight: UIFont.Weight = .regular, compatibleWith traits: UITraitCollection = .current) -> UIFont {
        UIFontMetrics(forTextStyle: .body).scaledFont(for: baseFont(size, weight: weight), compatibleWith: traits)
    }
    static func baseFont(_ size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        registerFonts()
        let traits = [UIFontDescriptor.TraitKey.weight: weight.rawValue]
        let fallback = UIFontDescriptor(fontAttributes: [.family: "Noto Sans SC", .traits: traits])
        let descriptor = UIFontDescriptor(fontAttributes: [
            .family: "Inter", .traits: traits, .cascadeList: [fallback]
        ])
        return UIFont(descriptor: descriptor, size: size)
    }
    static func body(_ size: CGFloat = 16, weight: UIFont.Weight = .regular) -> Font {
        Font.custom(baseFont(size, weight: weight).fontName, size: size, relativeTo: .body)
            .weight(weight >= .bold ? .bold : weight >= .semibold ? .semibold : weight >= .medium ? .medium : .regular)
    }
    static func mono(_ size: CGFloat = 13) -> Font {
        let font = TerminalFontRegistry.font(familyName: TerminalFontRegistry.defaultFamilyName, pointSize: Double(size)) ?? UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        return Font.custom(font.fontName, size: size, relativeTo: .caption)
    }
}

/// Original SVGs exported by Figma, compiled as template vector assets.
enum MudiIcon: String, CaseIterable {
    case plus = "Plus", settings = "Settings", ellipsis = "Ellipsis"
    case chevronRight = "ChevronRight", chevronLeft = "ChevronLeft"
    case retry = "Retry", search = "Search", close = "Close", refresh = "Refresh"
    case star = "Star", clock = "Clock", project = "Project", terminal = "Terminal"
    case grip = "Grip", minus = "Minus", move = "Move", paste = "Paste"
    case history = "History", compose = "Compose", layers = "Layers", keyboardHide = "KeyboardHide"
    case keyboard = "Keyboard"
    case origin = "Origin", originDot = "OriginDot", shiftTab = "ShiftTab", up = "Up"
    case arcPaste = "ArcPaste", arcLayers = "ArcLayers"
    case arcShiftTab = "ArcShiftTab", arcUp = "ArcUp", arcClipboard = "ArcClipboard", arcJump = "ArcJump"
    case down = "Down", right = "Right", left = "Left", dPadUp = "DPadUp"
    case unlock = "Unlock", backspace = "Backspace", clear = "Clear", enter = "Enter"
    case statusWaiting = "StatusWaiting", statusWorking = "StatusWorking", statusDone = "StatusDone"
    case statusIdle = "StatusIdle", statusFailed = "StatusFailed"
    case composeClose = "ComposeClose", composeMove = "ComposeMove", composeHistory = "ComposeHistory"
    case composeLayers = "ComposeLayers", composePlus = "ComposePlus", composeStar = "ComposeStar"
    case composeTarget = "ComposeTarget", composeClear = "ComposeClear", composeMic = "ComposeMic", composeSend = "ComposeSend"
    var assetName: String { "Mudi" + rawValue }
    @MainActor var uiImage: UIImage? { UIImage(named: assetName)?.withRenderingMode(.alwaysTemplate) }
    @MainActor var image: Image { Image(assetName).renderingMode(.template) }
}

struct MudiRoundButton: View {
    let icon: MudiIcon
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            icon.image
                .foregroundStyle(MudiPalette.ink)
                .frame(width: 36, height: 36)
                .background(MudiPalette.surface, in: Circle())
                .overlay(Circle().stroke(MudiPalette.border, lineWidth: 1))
                .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

struct MudiPillStyle: ButtonStyle {
    var filled = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(MudiTypography.body(13, weight: .medium))
            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(filled ? MudiPalette.canvas : MudiPalette.ink)
            .padding(.horizontal, 12)
            .frame(minHeight: 28)
            .background(filled ? MudiPalette.ink : .clear, in: Capsule())
            .overlay(Capsule().stroke(MudiPalette.ink, lineWidth: filled ? 0 : 1))
            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

struct MudiSectionHeader: View {
    let title: String
    var count: Int? = nil
    var icon: MudiIcon? = nil
    var body: some View {
        HStack(spacing: 6) {
            if let icon { icon.image }
            Text(title).font(MudiTypography.body(13, weight: .medium))
            Spacer()
            if let count { Text("\(count)").font(MudiTypography.mono(12)) }
        }
        .foregroundStyle(MudiPalette.mute)
        .textCase(nil)
        .padding(.horizontal, 4)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

extension View {
    func mudiGroupedList(background: Color = MudiPalette.canvas) -> some View {
        modifier(MudiGroupedListStyle(background: background))
    }
    func mudiRow() -> some View {
        self.listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14))
            .listRowBackground(MudiPalette.surface)
            .listRowSeparatorTint(MudiPalette.hairline)
            .foregroundStyle(MudiPalette.ink)
    }
}

extension ToolbarItem {
    @ToolbarContentBuilder
    func mudiToolbarBackground() -> some ToolbarContent {
        if #available(iOS 26.0, *) { self.sharedBackgroundVisibility(.hidden) }
        else { self }
    }
}
extension ToolbarItemGroup {
    @ToolbarContentBuilder
    func mudiToolbarBackground() -> some ToolbarContent {
        if #available(iOS 26.0, *) { self.sharedBackgroundVisibility(.hidden) }
        else { self }
    }
}

private struct MudiGroupedListStyle: ViewModifier {
    let background: Color
    @Environment(\.colorScheme) private var colorScheme
    func body(content: Content) -> some View {
        content.listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(background)
            .tint(MudiPalette.ink)
            .font(MudiTypography.body())
            .environment(\.defaultMinListRowHeight, 44)
            .listSectionSpacing(20)
            .toolbarColorScheme(colorScheme, for: .navigationBar)
            .toolbarBackground(background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
    }
}
