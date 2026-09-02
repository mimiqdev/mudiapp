import SwiftUI
import UIKit

struct TerminalAppearance {
    let theme: TerminalTheme
    let background: UIColor
    let foreground: UIColor

    init(theme: TerminalTheme) {
        self.init(
            theme: theme,
            background: theme.defaultBackground.uiColor,
            foreground: theme.defaultForeground.uiColor
        )
    }

    /// Keeps the original two-color construction seam available to callers
    /// that do not need a catalog theme.
    init(background: UIColor, foreground: UIColor) {
        self.init(
            theme: TerminalThemeRegistry.builtInThemes[0],
            background: background,
            foreground: foreground
        )
    }

    private init(theme: TerminalTheme, background: UIColor, foreground: UIColor) {
        self.theme = theme
        self.background = background
        self.foreground = foreground
    }

    static func colors(for colorScheme: ColorScheme) -> TerminalAppearance {
        let variant: TerminalThemeVariant = colorScheme == .dark ? .dark : .light
        let selection = TerminalThemeRegistry.defaultSelection
        let theme = TerminalThemeRegistry.resolve(selection, for: variant)
            ?? TerminalThemeRegistry.builtInThemes[0]
        let background: UIColor = colorScheme == .dark ? .black : .white
        let foreground: UIColor = colorScheme == .dark ? .white : .black
        return TerminalAppearance(
            theme: theme,
            background: background,
            foreground: foreground
        )
    }
}
