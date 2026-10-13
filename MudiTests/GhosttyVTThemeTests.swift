import GhosttyVt
import UIKit
import XCTest
@testable import Mudi

@MainActor
final class GhosttyVTThemeTests: XCTestCase {
    func testMudiThemesPaletteAndTrueColorMapToTheSameRealVTWithoutReset() throws {
        let view = try GhosttyVTView()
        let host = try XCTUnwrap(view as? any TerminalHost)
        let identity = ObjectIdentifier(view.terminal)
        _ = try view.feed(Data("keep\u{1b}[?1h\u{1b}[38;2;12;34;56mT".utf8))
        for theme in TerminalThemeRegistry.builtInThemes {
            try host.apply(theme: theme)
            XCTAssertEqual(host.appliedTheme, theme)
            XCTAssertEqual(view.screen.theme?.foreground, vt(theme.defaultForeground))
            XCTAssertEqual(view.screen.theme?.background, vt(theme.defaultBackground))
            XCTAssertEqual(view.screen.theme?.cursor, vt(theme.cursor))
            XCTAssertEqual(Array(view.screen.theme?.palette.prefix(16) ?? []), theme.ansi16.map(vt))
            XCTAssertEqual(view.screen.theme?.palette[196], .init(red: 255, green: 0, blue: 0))
            XCTAssertEqual(view.screen.rows[0]?.cells.first { $0.text == "T" }?.resolvedForeground,
                           .init(red: 12, green: 34, blue: 56))
            XCTAssertTrue(view.screen.text(at: 0).hasPrefix("keepT"))
            XCTAssertEqual(ObjectIdentifier(view.terminal), identity)
            XCTAssertEqual(try view.terminal.encode(.init(key: .arrowUp)), Data("\u{1b}OA".utf8))
        }
        host.updateFont(familyName: TerminalFontRegistry.defaultFamilyName, pointSize: 21)
        XCTAssertEqual(view.font.familyName, TerminalFontRegistry.defaultFamilyName)
        XCTAssertEqual(view.font.pointSize, 21)
        XCTAssertEqual(ObjectIdentifier(view.terminal), identity)
    }

    func testExplicitExtendedPaletteIsNotQuantizedOrReplacedWithXterm() throws {
        let view = try GhosttyVTView()
        let host = try XCTUnwrap(view as? any TerminalHost)
        let base = TerminalThemeRegistry.builtInThemes[0]
        let palette = (0..<240).map { TerminalRGBColor(red: UInt8($0), green: 23, blue: 45) }
        let theme = TerminalTheme(name: "explicit", family: base.family, variant: base.variant, ansi16: base.ansi16,
            defaultForeground: base.defaultForeground, defaultBackground: base.defaultBackground, bold: base.bold,
            cursor: base.cursor, selection: base.selection, extendedPaletteStrategy: .explicit(palette),
            extendedPaletteDocumentation: "test fixture", source: base.source)
        try host.apply(theme: theme)
        _ = try view.feed(Data("\u{1b}[38;5;200mP\u{1b}[0m".utf8))
        XCTAssertEqual(view.screen.theme?.palette[200], vt(palette[184]))
        XCTAssertEqual(view.screen.rows[0]?.cells[0].resolvedForeground, vt(palette[184]))
    }

    func testLabAndHarmoniousPoliciesMatchIndependentSwiftTermPaletteQueries() async throws {
        // SwiftTerm is only the independent test oracle; the VT renderer's
        // production palette path owns its math and never instantiates it.
        for base in [TerminalThemeRegistry.builtInThemes[0], TerminalThemeRegistry.builtInThemes[1]] {
            for strategy in [TerminalThemePaletteStrategy.base16Lab, .base16LabHarmonious] {
                let theme = TerminalTheme(name: "LAB oracle", family: base.family, variant: base.variant, ansi16: base.ansi16,
                    defaultForeground: base.defaultForeground, defaultBackground: base.defaultBackground, bold: base.bold,
                    cursor: base.cursor, selection: base.selection, extendedPaletteStrategy: strategy,
                    extendedPaletteDocumentation: "Independent comparison", source: base.source)
                let reference = Phase8TerminalHarness(theme: theme)
                defer { reference.stop() }
                let view = try GhosttyVTView()
                try (try XCTUnwrap(view as? any TerminalHost)).apply(theme: theme)
                for index in [16, 21, 51, 88, 124, 196, 216, 232, 244, 255] {
                    let queried = await reference.queryColor(at: index)
                    let expected = try XCTUnwrap(queried)
                    let actual = try XCTUnwrap(view.screen.theme?.palette[index])
                    XCTAssertEqual(Int(actual.red), Int(expected.red), accuracy: 1, "\(strategy) index \(index)")
                    XCTAssertEqual(Int(actual.green), Int(expected.green), accuracy: 1, "\(strategy) index \(index)")
                    XCTAssertEqual(Int(actual.blue), Int(expected.blue), accuracy: 1, "\(strategy) index \(index)")
                }
            }
        }
    }

    private func vt(_ color: TerminalRGBColor) -> TerminalFrame.RGBColor {
        .init(red: color.red, green: color.green, blue: color.blue)
    }
}
