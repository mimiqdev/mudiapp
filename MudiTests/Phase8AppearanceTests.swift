import CoreText
import Foundation
import UIKit
import XCTest
@preconcurrency import SwiftTerm
@testable import Mudi

@MainActor
final class Phase8AppearanceTests: XCTestCase {
    private let requiredThemeNames: Set<String> = [
        "Mudi Default Light",
        "Mudi Default Dark",
        "Solarized Light",
        "Solarized Dark",
        "Catppuccin Latte",
        "Catppuccin Mocha",
        "Monokai Dark",
    ]

    func testOSC4ParserAcceptsBELAndSTTerminatedRGBReplies() {
        let stReply = Array("4;7;rgb:1111/3333/5555".utf8)
            + [27, 92]
        XCTAssertEqual(
            phase8RGBColor(from: stReply),
            TerminalRGBColor(red: 17, green: 51, blue: 85)
        )

        let belReply = Array("4;8;rgb:aaaa/bbbb/cccc".utf8) + [7]
        XCTAssertEqual(
            phase8RGBColor(from: belReply),
            TerminalRGBColor(red: 170, green: 187, blue: 204)
        )
    }

    func testEveryBuiltInThemeHasTheCompletePaletteContractAndProvenance() {
        let themes = TerminalThemeRegistry.builtInThemes
        let names = Set(themes.map(\.name))

        XCTAssertGreaterThanOrEqual(
            themes.count,
            9,
            "The registry needs the named themes plus a further clear Light/Dark pair"
        )
        XCTAssertEqual(
            names.intersection(requiredThemeNames),
            requiredThemeNames,
            "The built-in list must include every plan-approved theme"
        )
        XCTAssertFalse(
            names.contains("Monokai Light"),
            "There is no official Monokai Light palette to invent"
        )
        XCTAssertEqual(
            names.count,
            themes.count,
            "Theme names must be stable and unique"
        )

        for theme in themes {
            XCTAssertEqual(
                theme.ansi16.count,
                16,
                "\(theme.name) must declare all ANSI 0–15 anchors"
            )
            XCTAssertFalse(theme.family.trimmingCharacters(in: .whitespaces).isEmpty)
            XCTAssertFalse(
                theme.extendedPaletteDocumentation
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty,
                "\(theme.name) must document its 16–255 strategy"
            )
            let strategyDocumentation = theme.extendedPaletteDocumentation
                .lowercased()
            XCTAssertTrue(
                strategyDocumentation.contains("16")
                    && strategyDocumentation.contains("255"),
                "\(theme.name) must document the complete extension range"
            )

            switch theme.extendedPaletteStrategy {
            case .xterm, .base16Lab, .base16LabHarmonious:
                break
            case let .explicit(colors):
                XCTAssertEqual(
                    colors.count,
                    240,
                    "An explicit strategy must provide entries for ANSI 16–255"
                )
            }

            XCTAssertFalse(
                theme.source.repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            )
            XCTAssertEqual(
                URL(string: theme.source.repositoryURL)?.scheme,
                "https",
                "\(theme.name) must record an HTTPS source repository"
            )
            XCTAssertFalse(
                theme.source.license.trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty,
                "\(theme.name) must record its license"
            )
            XCTAssertFalse(
                theme.source.attribution.trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty,
                "\(theme.name) must record attribution/provenance"
            )

        }

        let extraThemes = themes.filter { !requiredThemeNames.contains($0.name) }
        let extraFamilies = Dictionary(grouping: extraThemes, by: \.family)
        let hasAdditionalLightDarkPair = extraFamilies.values.contains { family in
            let variants = Set(family.map(\.variant))
            return variants.contains(.light) && variants.contains(.dark)
        }
        XCTAssertTrue(
            hasAdditionalLightDarkPair,
            "The final registry must include another license-clear classic Light/Dark pair"
        )
    }

    func testAutomaticPairAndFixedThemeSelectionsResolveToTheRequestedPalette() throws {
        let light = try XCTUnwrap(
            TerminalThemeRegistry.theme(named: "Solarized Light")
        )
        let dark = try XCTUnwrap(
            TerminalThemeRegistry.theme(named: "Solarized Dark")
        )
        let automatic = TerminalThemeSelection.automatic(
            light: light.name,
            dark: dark.name
        )

        XCTAssertEqual(
            TerminalThemeRegistry.resolve(automatic, for: .light),
            light,
            "Automatic must choose the Light member of its pair"
        )
        XCTAssertEqual(
            TerminalThemeRegistry.resolve(automatic, for: .dark),
            dark,
            "Automatic must choose the Dark member of its pair"
        )
        XCTAssertEqual(
            TerminalThemeRegistry.resolve(
                .fixedLight(light.name),
                for: .dark
            ),
            light,
            "A fixed Light choice must not follow a later system change"
        )
        XCTAssertEqual(
            TerminalThemeRegistry.resolve(
                .fixedDark(dark.name),
                for: .light
            ),
            dark,
            "A fixed Dark choice must not follow a later system change"
        )
    }

    func testApplyingEveryThemeKeepsAnsiAnchorsAndAllExtendedEntriesAvailable() async throws {
        let themes = TerminalThemeRegistry.builtInThemes
        guard !themes.isEmpty else {
            XCTFail("The phase-8 theme registry is not implemented")
            return
        }

        for theme in themes {
            if case .explicit = theme.extendedPaletteStrategy {
                XCTFail(
                    "\(theme.name) requires an explicit 256-colour installation path; "
                        + "the test must not silently map it to xterm"
                )
                continue
            }

            let harness = Phase8TerminalHarness(theme: theme)
            defer { harness.stop() }
            let terminalView = harness.terminalView

            XCTAssertEqual(
                terminalView.appliedTheme,
                theme,
                "The product view must retain every applied theme anchor, including bold"
            )
            XCTAssertEqual(
                terminalView.nativeForegroundColor,
                phase8UIKitColor(theme.defaultForeground),
                "\(theme.name) must install its default foreground on the product view"
            )
            XCTAssertEqual(
                terminalView.nativeBackgroundColor,
                phase8UIKitColor(theme.defaultBackground),
                "\(theme.name) must install its default background on the product view"
            )
            XCTAssertEqual(
                harness.terminal.foregroundColor,
                phase8SwiftTermColor(theme.defaultForeground),
                "\(theme.name) must install its default foreground in SwiftTerm"
            )
            XCTAssertEqual(
                harness.terminal.backgroundColor,
                phase8SwiftTermColor(theme.defaultBackground),
                "\(theme.name) must install its default background in SwiftTerm"
            )
            XCTAssertEqual(
                harness.terminal.cursorColor,
                Optional(phase8SwiftTermColor(theme.cursor)),
                "\(theme.name) must install its cursor colour in SwiftTerm"
            )
            XCTAssertEqual(
                terminalView.caretColor,
                phase8UIKitColor(theme.cursor),
                "\(theme.name) must install its cursor colour on the product view"
            )
            XCTAssertEqual(
                terminalView.selectedTextBackgroundColor,
                phase8UIKitColor(theme.selection),
                "\(theme.name) must install its selection colour on the product view"
            )
            assertSwiftTermStrategy(
                harness.terminal.options.ansi256PaletteStrategy,
                matches: theme.extendedPaletteStrategy,
                themeName: theme.name
            )

            for (index, anchor) in theme.ansi16.enumerated() {
                let actual = await harness.queryColor(at: index)
                XCTAssertEqual(
                    actual,
                    anchor,
                    "\(theme.name) changed its ANSI anchor at index \(index)"
                )
            }

            var availableExtendedEntries = 0
            for index in 16...255 {
                guard let actual = await harness.queryColor(at: index) else {
                    XCTFail(
                        "\(theme.name) did not expose a colour for ANSI index \(index)"
                    )
                    continue
                }
                availableExtendedEntries += 1

                switch theme.extendedPaletteStrategy {
                case .xterm:
                    XCTAssertEqual(
                        actual,
                        phase8XtermColor(at: index),
                        "\(theme.name) did not use the declared xterm strategy"
                    )
                case .explicit:
                    XCTFail(
                        "\(theme.name) reached the palette sweep without an explicit path"
                    )
                case .base16Lab, .base16LabHarmonious:
                    // The resolved SwiftTerm implementation owns the LAB
                    // interpolation. The complete query sweep above proves
                    // that the declared strategy produces 240 entries rather
                    // than silently falling back to a 16-colour terminal.
                    break
                }
            }
            XCTAssertEqual(
                availableExtendedEntries,
                240,
                "\(theme.name) must expose every ANSI index 16–255"
            )
        }
    }

    func testIndexedAndTrueColorAttributesRemainProgramSpecifiedAfterThemeApplication() throws {
        let themes = TerminalThemeRegistry.builtInThemes
        guard !themes.isEmpty else {
            XCTFail("The phase-8 theme registry is not implemented")
            return
        }

        for theme in themes {
            let harness = Phase8TerminalHarness(theme: theme)
            defer { harness.stop() }
            harness.terminal.feed(
                text: "\u{1b}[38;5;201;48;5;33mI"
            )
            let indexed = try XCTUnwrap(
                harness.terminal.getCharData(col: 0, row: 0),
                "Indexed colour output did not reach SwiftTerm"
            )
            XCTAssertEqual(indexed.attribute.fg, .ansi256(code: 201))
            XCTAssertEqual(indexed.attribute.bg, .ansi256(code: 33))

            let red: UInt8 = 17
            let green: UInt8 = 34
            let blue: UInt8 = 51
            let backgroundRed: UInt8 = 201
            let backgroundGreen: UInt8 = 202
            let backgroundBlue: UInt8 = 203
            harness.terminal.feed(
                text: "\u{1b}[38;2;\(red);\(green);\(blue);"
                    + "48;2;\(backgroundRed);\(backgroundGreen);\(backgroundBlue)mT"
            )
            let trueColor = try XCTUnwrap(
                harness.terminal.getCharData(col: 1, row: 0),
                "True-color output did not reach SwiftTerm"
            )
            XCTAssertEqual(
                trueColor.attribute.fg,
                .trueColor(red: red, green: green, blue: blue),
                "\(theme.name) altered program-specified foreground RGB"
            )
            XCTAssertEqual(
                trueColor.attribute.bg,
                .trueColor(
                    red: backgroundRed,
                    green: backgroundGreen,
                    blue: backgroundBlue
                ),
                "\(theme.name) altered program-specified background RGB"
            )
        }
    }

    func testPTYEnvironmentDeclarationsCoverShellControlAndMoshBootstrap() {
        let declarations = TerminalPTYCapabilities.declarations
        XCTAssertEqual(
            Set(declarations.map(\.sessionKind)),
            Set(TerminalSessionKind.allCases),
            "Every PTY creation site must publish a capability declaration"
        )
        XCTAssertEqual(
            declarations.count,
            TerminalSessionKind.allCases.count,
            "PTY capability declarations must not silently omit a session"
        )

        for declaration in declarations {
            XCTAssertEqual(
                declaration.environment["TERM"],
                "xterm-256color",
                "\(declaration.sessionKind) must advertise 256-colour TERM"
            )
            XCTAssertEqual(
                declaration.environment["COLORTERM"],
                "truecolor",
                "\(declaration.sessionKind) must advertise true colour"
            )
        }
    }

    private func assertSwiftTermStrategy(
        _ actual: Ansi256PaletteStrategy,
        matches expected: TerminalThemePaletteStrategy,
        themeName: String
    ) {
        switch (actual, expected) {
        case (.xterm, .xterm):
            break
        case (.base16Lab, .base16Lab):
            break
        case (.base16LabHarmonious, .base16LabHarmonious):
            break
        case (_, .explicit):
            XCTFail(
                "\(themeName) declares an explicit palette without a supported "
                    + "256-colour installation path"
            )
        default:
            XCTFail("\(themeName) did not install its declared SwiftTerm strategy")
        }
    }
}
