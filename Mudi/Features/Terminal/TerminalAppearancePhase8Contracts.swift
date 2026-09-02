import Foundation
import UIKit

/// A lossless 8-bit RGB value used by the terminal theme catalog.
struct TerminalRGBColor: Codable, Equatable, Hashable, Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Creates a color from the six-digit sRGB values published by a theme.
    /// The catalog only calls this with checked, literal theme values.
    init(hex: String) {
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard value.count == 6, let number = UInt32(value, radix: 16) else {
            self.init(red: 0, green: 0, blue: 0)
            return
        }
        self.init(
            red: UInt8((number >> 16) & 0xff),
            green: UInt8((number >> 8) & 0xff),
            blue: UInt8(number & 0xff)
        )
    }
}

enum TerminalThemeVariant: String, Codable, CaseIterable, Hashable, Sendable {
    case light
    case dark
}

enum TerminalThemePaletteStrategy: Codable, Equatable, Hashable, Sendable {
    case xterm
    case base16Lab
    case base16LabHarmonious
    case explicit([TerminalRGBColor])
}

struct TerminalThemeSource: Codable, Equatable, Hashable, Sendable {
    let repositoryURL: String
    let license: String
    let attribution: String
}

struct TerminalFontDescriptor: Codable, Equatable, Hashable, Sendable {
    let familyName: String
    let resourceName: String
    let fileExtension: String
    let license: String
    let sourceURL: String
}

struct TerminalFontSelection: Codable, Equatable, Hashable, Sendable {
    let familyName: String
    let pointSize: Double
}

struct TerminalTheme: Codable, Equatable, Hashable, Sendable {
    let name: String
    let family: String
    let variant: TerminalThemeVariant
    let ansi16: [TerminalRGBColor]
    let defaultForeground: TerminalRGBColor
    let defaultBackground: TerminalRGBColor
    let bold: TerminalRGBColor
    let cursor: TerminalRGBColor
    let selection: TerminalRGBColor
    let extendedPaletteStrategy: TerminalThemePaletteStrategy
    let extendedPaletteDocumentation: String
    let source: TerminalThemeSource
}

enum TerminalThemeSelection: Codable, Equatable, Hashable, Sendable {
    case automatic(light: String, dark: String)
    case fixedLight(String)
    case fixedDark(String)
}

/// The built-in terminal palette catalog.
///
/// The ANSI values below are copied from the repositories recorded in each
/// theme's ``TerminalThemeSource``.  A theme is never represented by a
/// guessed color or by a generic name with no provenance.  None of the
/// selected upstream terminal files publishes a complete 16–255 table, so
/// every built-in theme explicitly uses SwiftTerm's documented xterm cube and
/// grayscale extension.
enum TerminalThemeRegistry {
    static let defaultSelection = TerminalThemeSelection.automatic(
        light: "Mudi Default Light",
        dark: "Mudi Default Dark"
    )

    static let builtInThemes: [TerminalTheme] = [
        makeTheme(
            name: "Mudi Default Light",
            family: "Mudi Default",
            variant: .light,
            palette: ThemePalette(values: [
                "#000000", "#c23621", "#25bc24", "#adad27",
                "#492ee1", "#d338d3", "#33bbc8", "#cbcccd",
                "#818383", "#fc391f", "#31e722", "#eaec23",
                "#5833ff", "#f935f8", "#14f0f0", "#e9ebeb",
                "#000000", "#ffffff", "#000000", "#000000", "#00a6b2",
            ]),
            source: TerminalThemeSource(
                repositoryURL: "https://github.com/migueldeicaza/SwiftTerm",
                license: "MIT",
                attribution: "Mudi's default light surfaces plus SwiftTerm's official terminalAppColors palette."
            )
        ),
        makeTheme(
            name: "Mudi Default Dark",
            family: "Mudi Default",
            variant: .dark,
            palette: ThemePalette(values: [
                "#000000", "#c23621", "#25bc24", "#adad27",
                "#492ee1", "#d338d3", "#33bbc8", "#cbcccd",
                "#818383", "#fc391f", "#31e722", "#eaec23",
                "#5833ff", "#f935f8", "#14f0f0", "#e9ebeb",
                "#e9ebeb", "#000000", "#e9ebeb", "#e9ebeb", "#00a6b2",
            ]),
            source: TerminalThemeSource(
                repositoryURL: "https://github.com/migueldeicaza/SwiftTerm",
                license: "MIT",
                attribution: "Mudi's default dark surfaces plus SwiftTerm's official terminalAppColors palette."
            )
        ),
        makeTheme(
            name: "Solarized Light",
            family: "Solarized",
            variant: .light,
            palette: ThemePalette(values: [
                "#073642", "#dc322f", "#859900", "#b58900",
                "#268bd2", "#d33682", "#2aa198", "#eee8d5",
                "#002b36", "#cb4b16", "#586e75", "#657b83",
                "#839496", "#6c71c4", "#93a1a1", "#fdf6e3",
                "#657b83", "#fdf6e3", "#586e75", "#586e75", "#eee8d5",
            ]),
            source: TerminalThemeSource(
                repositoryURL: "https://github.com/altercation/solarized",
                license: "MIT",
                attribution: "Ethan Schoonover's official Solarized xresources and terminal palette."
            )
        ),
        makeTheme(
            name: "Solarized Dark",
            family: "Solarized",
            variant: .dark,
            palette: ThemePalette(values: [
                "#073642", "#dc322f", "#859900", "#b58900",
                "#268bd2", "#d33682", "#2aa198", "#eee8d5",
                "#002b36", "#cb4b16", "#586e75", "#657b83",
                "#839496", "#6c71c4", "#93a1a1", "#fdf6e3",
                "#839496", "#002b36", "#93a1a1", "#93a1a1", "#073642",
            ]),
            source: TerminalThemeSource(
                repositoryURL: "https://github.com/altercation/solarized",
                license: "MIT",
                attribution: "Ethan Schoonover's official Solarized xresources and terminal palette."
            )
        ),
        makeTheme(
            name: "Catppuccin Latte",
            family: "Catppuccin",
            variant: .light,
            palette: ThemePalette(values: [
                "#bcc0cc", "#d20f39", "#40a02b", "#df8e1d",
                "#1e66f5", "#ea76cb", "#179299", "#5c5f77",
                "#acb0be", "#d20f39", "#40a02b", "#df8e1d",
                "#1e66f5", "#ea76cb", "#179299", "#6c6f85",
                "#4c4f69", "#eff1f5", "#4c4f69", "#dc8a78", "#dc8a78",
            ]),
            source: TerminalThemeSource(
                repositoryURL: "https://github.com/catppuccin/alacritty",
                license: "MIT",
                attribution: "Catppuccin's official Latte Alacritty palette."
            )
        ),
        makeTheme(
            name: "Catppuccin Mocha",
            family: "Catppuccin",
            variant: .dark,
            palette: ThemePalette(values: [
                "#45475a", "#f38ba8", "#a6e3a1", "#f9e2af",
                "#89b4fa", "#f5c2e7", "#94e2d5", "#bac2de",
                "#585b70", "#f38ba8", "#a6e3a1", "#f9e2af",
                "#89b4fa", "#f5c2e7", "#94e2d5", "#a6adc8",
                "#cdd6f4", "#1e1e2e", "#cdd6f4", "#f5e0dc", "#f5e0dc",
            ]),
            source: TerminalThemeSource(
                repositoryURL: "https://github.com/catppuccin/alacritty",
                license: "MIT",
                attribution: "Catppuccin's official Mocha Alacritty palette."
            )
        ),
        makeTheme(
            name: "Monokai Dark",
            family: "Monokai",
            variant: .dark,
            palette: ThemePalette(values: [
                "#333333", "#c4265e", "#86b42b", "#b3b42b",
                "#6a7ec8", "#8c6bc8", "#56adbc", "#e3e3dd",
                "#666666", "#f92672", "#a6e22e", "#e2e22e",
                "#819aff", "#ae81ff", "#66d9ef", "#f8f8f2",
                "#f8f8f2", "#272822", "#f8f8f2", "#f8f8f0", "#878b91",
            ]),
            source: TerminalThemeSource(
                repositoryURL: "https://github.com/microsoft/vscode/tree/main/extensions/theme-monokai",
                license: "MIT",
                attribution: "Microsoft VS Code's official Monokai theme, based on the original Monokai palette."
            )
        ),
        makeTheme(
            name: "Gruvbox Light",
            family: "Gruvbox",
            variant: .light,
            palette: ThemePalette(values: [
                "#fbf1c7", "#cc241d", "#98971a", "#d79921",
                "#458588", "#b16286", "#689d6a", "#7c6f64",
                "#928374", "#9d0006", "#79740e", "#b57614",
                "#076678", "#8f3f71", "#427b58", "#3c3836",
                "#3c3836", "#fbf1c7", "#282828", "#af3a03", "#bdae93",
            ]),
            source: TerminalThemeSource(
                repositoryURL: "https://github.com/morhetz/gruvbox",
                license: "MIT",
                attribution: "Pavel Pertsev's official Gruvbox Vim terminal colors (light mode)."
            )
        ),
        makeTheme(
            name: "Gruvbox Dark",
            family: "Gruvbox",
            variant: .dark,
            palette: ThemePalette(values: [
                "#282828", "#cc241d", "#98971a", "#d79921",
                "#458588", "#b16286", "#689d6a", "#a89984",
                "#928374", "#fb4934", "#b8bb26", "#fabd2f",
                "#83a598", "#d3869b", "#8ec07c", "#ebdbb2",
                "#ebdbb2", "#282828", "#fbf1c7", "#fe8019", "#665c54",
            ]),
            source: TerminalThemeSource(
                repositoryURL: "https://github.com/morhetz/gruvbox",
                license: "MIT",
                attribution: "Pavel Pertsev's official Gruvbox Vim terminal colors (dark mode)."
            )
        ),
    ]

    static func theme(named name: String) -> TerminalTheme? {
        builtInThemes.first { $0.name == name }
    }

    static func resolve(
        _ selection: TerminalThemeSelection,
        for variant: TerminalThemeVariant
    ) -> TerminalTheme? {
        let name: String
        switch selection {
        case let .automatic(light, dark):
            name = variant == .light ? light : dark
        case let .fixedLight(fixedName), let .fixedDark(fixedName):
            name = fixedName
        }
        return theme(named: name)
    }

    /// Values shown by the Settings picker.  Automatic choices are paired
    /// first; fixed choices then expose every concrete built-in palette.
    static var selectionOptions: [TerminalThemeSelection] {
        let automaticPairs = Dictionary(grouping: builtInThemes, by: \.family)
            .compactMap { _, themes -> TerminalThemeSelection? in
                guard let light = themes.first(where: { $0.variant == .light }),
                      let dark = themes.first(where: { $0.variant == .dark })
                else { return nil }
                return .automatic(light: light.name, dark: dark.name)
            }
            .sorted { label(for: $0) < label(for: $1) }
        let fixed = builtInThemes.map { theme in
            switch theme.variant {
            case .light:
                return TerminalThemeSelection.fixedLight(theme.name)
            case .dark:
                return TerminalThemeSelection.fixedDark(theme.name)
            }
        }
        return automaticPairs + fixed
    }

    static func label(for selection: TerminalThemeSelection) -> String {
        switch selection {
        case let .automatic(light, _):
            return "\(theme(named: light)?.family ?? light) (Automatic)"
        case let .fixedLight(name), let .fixedDark(name):
            return theme(named: name)?.name ?? name
        }
    }

    private static func makeTheme(
        name: String,
        family: String,
        variant: TerminalThemeVariant,
        palette: ThemePalette,
        source: TerminalThemeSource
    ) -> TerminalTheme {
        precondition(palette.ansi.count == 16)
        return TerminalTheme(
            name: name,
            family: family,
            variant: variant,
            ansi16: palette.ansi.map(TerminalRGBColor.init(hex:)),
            defaultForeground: TerminalRGBColor(hex: palette.foreground),
            defaultBackground: TerminalRGBColor(hex: palette.background),
            bold: TerminalRGBColor(hex: palette.bold),
            cursor: TerminalRGBColor(hex: palette.cursor),
            selection: TerminalRGBColor(hex: palette.selection),
            extendedPaletteStrategy: .xterm,
            extendedPaletteDocumentation: "ANSI indexes 16–255 use SwiftTerm's xterm 6×6×6 cube for 16–231 and grayscale ramp for 232–255.",
            source: source
        )
    }

    private struct ThemePalette {
        let ansi: [String]
        let foreground: String
        let background: String
        let bold: String
        let cursor: String
        let selection: String

        init(values: [String]) {
            precondition(values.count == 21)
            ansi = Array(values.prefix(16))
            foreground = values[16]
            background = values[17]
            bold = values[18]
            cursor = values[19]
            selection = values[20]
        }
    }
}

extension TerminalRGBColor {
    var uiColor: UIColor {
        UIColor(
            red: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: 1
        )
    }
}

enum TerminalSessionKind: String, CaseIterable, Codable, Hashable, Sendable {
    case sshShell
    case sshControlChannel
    case moshBootstrap
}

struct TerminalPTYCapabilityDeclaration: Codable, Equatable, Hashable, Sendable {
    let sessionKind: TerminalSessionKind
    let environment: [String: String]
}

enum TerminalPTYCapabilities {
    static let environment: [String: String] = [
        "TERM": "xterm-256color",
        "COLORTERM": "truecolor",
    ]

    static var declarations: [TerminalPTYCapabilityDeclaration] {
        TerminalSessionKind.allCases.map {
            TerminalPTYCapabilityDeclaration(
                sessionKind: $0,
                environment: environment
            )
        }
    }

    /// Shell syntax used for commands whose SSH channel does not expose a
    /// PTY environment request (notably Herdr's control exec and Mosh's
    /// bootstrap command).
    static var shellExportPrefix: String {
        environment.keys.sorted().map { key in
            "export \(key)=\(shellQuote(environment[key] ?? ""))"
        }.joined(separator: "; ")
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
