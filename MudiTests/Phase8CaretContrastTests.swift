import UIKit
import XCTest
@testable import Mudi

@MainActor
final class Phase8CaretContrastTests: XCTestCase {
    func testDefaultThemeBlockCaretTextUsesThemeBackgroundForContrast() {
        let defaultThemes = TerminalThemeRegistry.builtInThemes.filter {
            $0.name == "Mudi Default Light" || $0.name == "Mudi Default Dark"
        }

        for theme in defaultThemes {
            let terminalView = ShellTerminalView(frame: .zero)
            terminalView.apply(theme: theme)
            XCTAssertEqual(
                terminalView.caretTextColor,
                phase8UIKitColor(theme.defaultBackground),
                "\(theme.name) block carets must draw their cell glyph against the theme background"
            )
            XCTAssertNotEqual(
                terminalView.caretColor,
                terminalView.caretTextColor,
                "\(theme.name) cursor fill and block-caret text must contrast"
            )
            terminalView.stop()
        }
    }
}
