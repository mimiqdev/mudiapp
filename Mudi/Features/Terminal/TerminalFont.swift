import CoreText
import UIKit

/// Provides the system terminal face with bundled Nerd Font symbols as a
/// fallback. The bundled Symbols Nerd Font is intentionally not used for
/// ordinary letters; the upstream release describes it as a fallback font.
@MainActor
enum TerminalFont {
    private static let symbolsFamilyName = "Symbols Nerd Font Mono"
    private static var didRegisterSymbols = false

    static func font(ofSize size: Double) -> UIFont {
        guard size.isFinite, size > 0 else {
            return UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        }

        registerSymbolsIfNeeded()
        let pointSize = CGFloat(size)
        let baseFont = UIFont.monospacedSystemFont(
            ofSize: pointSize,
            weight: .regular
        )
        guard let symbolsFont = UIFont(
            name: symbolsFamilyName,
            size: pointSize
        ) else {
            return baseFont
        }

        let descriptor = baseFont.fontDescriptor.addingAttributes([
            .cascadeList: [symbolsFont.fontDescriptor]
        ])
        return UIFont(descriptor: descriptor, size: pointSize)
    }

    private static func registerSymbolsIfNeeded() {
        guard !didRegisterSymbols,
              let url = Bundle.main.url(
                  forResource: "SymbolsNerdFontMono-Regular",
                  withExtension: "ttf"
              )
        else { return }

        var error: Unmanaged<CFError>?
        _ = CTFontManagerRegisterFontsForURL(
            url as CFURL,
            .process,
            &error
        )
        didRegisterSymbols = true
    }
}
