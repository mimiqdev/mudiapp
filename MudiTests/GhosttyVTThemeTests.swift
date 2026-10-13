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

    /// SwiftTerm 1.15 (`dd2fb8ac`) default `useBrightColors` maps a bold
    /// palette index `ansi < 7` to `ansi + 8` (index 7 is NOT brightened);
    /// 38;5;N shares the same index; explicit bright/256/truecolor/default and
    /// backgrounds are unchanged; inverse swaps first, then brightens the new
    /// foreground. Real SGR → real VT → CoreGraphics pixels, against both the
    /// explicit palette index and an independent SwiftTerm view's pixels.
    func testBoldANSIUsesSwiftTermBrightPaletteInBuiltInLightAndDarkThemes() throws {
        let block = "\u{2588}"
        // (SGR, expected palette index or nil for an explicit RGB/default colour)
        let items: [(sgr: String, text: String, index: Int?, rgb: TerminalRGBColor?)] = [
            ("1;31", block, 9, nil), ("31", block, 1, nil), ("1;31m\u{1b}[22", block, 1, nil),
            ("1;32", block, 10, nil), ("1;34", block, 12, nil), ("1;36", block, 14, nil),
            ("1;37", block, 7, nil), ("1;91", block, 9, nil), ("1;97", block, 15, nil),
            ("1;38;5;1", block, 9, nil), ("1;38;5;6", block, 14, nil), ("1;38;5;7", block, 7, nil),
            ("1;38;5;9", block, 9, nil), ("1;38;5;196", block, 196, nil),
            ("1;38;2;12;200;56", block, nil, .init(red: 12, green: 200, blue: 56)),
            ("1;7;32;41", block, 9, nil), ("1;7;32;41", " ", 2, nil),
        ]
        let stream = items.map { "\u{1b}[0m \u{1b}[\($0.sgr)m\($0.text)" }.joined() + "\u{1b}[0m\u{1b}[?25l"
        for theme in [TerminalThemeRegistry.builtInThemes[0], TerminalThemeRegistry.builtInThemes[1]] {
            let view = try GhosttyVTView(configuration: .init(columns: 40, rows: 2))
            try (try XCTUnwrap(view as? any TerminalHost)).apply(theme: theme)
            _ = try view.feed(Data(stream.utf8))
            let palette = try XCTUnwrap(view.screen.theme?.palette)
            let image = render(view, size: CGSize(width: view.cellSize.width * 40, height: view.cellSize.height * 2))
            let attachment = XCTAttachment(image: image)
            attachment.name = "GhosttyVT-bold-bright-\(theme.name)"
            attachment.lifetime = .keepAlways
            add(attachment)
            let y = view.cellSize.height / 2
            for (offset, item) in items.enumerated() {
                let x = view.cellSize.width * (CGFloat(offset * 2 + 1) + 0.5)
                let actual = try pixel(image, at: CGPoint(x: x, y: y))
                let expected = item.rgb.map(vt) ?? palette[item.index!]
                assert(actual, equals: expected, "\(theme.name) SGR \(item.sgr) \(item.text.debugDescription)")
            }
            XCTAssertEqual(view.screen.rows[0]?.cells.first { $0.text == block }?.style.isBold, true)
            XCTAssertEqual(palette[9], vt(theme.ansi16[9]))

            // Independent oracle: the default SwiftTerm engine renders the same bytes.
            let reference = Phase8TerminalHarness(theme: theme)
            defer { reference.stop() }
            let swiftTerm = reference.terminalView
            swiftTerm.frame = CGRect(x: 0, y: 0, width: view.cellSize.width * 80, height: view.cellSize.height * 4)
            swiftTerm.layoutIfNeeded()
            reference.terminal.feed(text: stream)
            let oracle = render(swiftTerm, size: swiftTerm.bounds.size)
            let oracleAttachment = XCTAttachment(image: oracle)
            oracleAttachment.name = "SwiftTerm-bold-bright-oracle-\(theme.name)"
            oracleAttachment.lifetime = .keepAlways
            add(oracleAttachment)
            let oracleRuns = try runs(in: oracle, background: theme.defaultBackground, count: items.count)
            let vtRuns = try runs(in: image, background: theme.defaultBackground, count: items.count)
            XCTAssertEqual(oracleRuns.count, items.count, "SwiftTerm oracle must show every sample")
            XCTAssertEqual(vtRuns.count, items.count)
            for (offset, pair) in zip(vtRuns, oracleRuns).enumerated() {
                assert(pair.0, equals: .init(red: UInt8(pair.1[0]), green: UInt8(pair.1[1]), blue: UInt8(pair.1[2])),
                       "\(theme.name) SwiftTerm parity for SGR \(items[offset].sgr) \(items[offset].text.debugDescription)")
            }
        }
    }

    private func render(_ view: UIView, size: CGSize) -> UIImage {
        view.frame = CGRect(origin: .zero, size: size)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        view.setNeedsDisplay()
        view.layer.displayIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { view.layer.render(in: $0.cgContext) }
    }

    private func pixels(_ image: UIImage) throws -> (bytes: [UInt8], width: Int, height: Int) {
        let cg = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: cg.width, height: cg.height, bitsPerComponent: 8,
            bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return (bytes, cg.width, cg.height)
    }

    private func pixel(_ image: UIImage, at point: CGPoint) throws -> [Int] {
        let data = try pixels(image)
        let offset = (Int(point.y) * data.width + Int(point.x)) * 4
        return data.bytes[offset..<offset + 3].map(Int.init)
    }

    /// Colour at the centre of each horizontal run that differs from the
    /// default background, on the middle scanline of those showing exactly
    /// `count` runs (avoids antialiased glyph edges). Engine-independent:
    /// needs no private SwiftTerm cell geometry.
    private func runs(in image: UIImage, background: TerminalRGBColor, count: Int) throws -> [[Int]] {
        let data = try pixels(image)
        var matches: [[[Int]]] = []
        var best: [[Int]] = []
        for y in 0..<min(data.height, 60) {
            var found: [[Int]] = []
            var start: Int?
            func differs(_ x: Int) -> Bool {
                let o = (y * data.width + x) * 4
                return abs(Int(data.bytes[o]) - Int(background.red)) + abs(Int(data.bytes[o + 1]) - Int(background.green))
                    + abs(Int(data.bytes[o + 2]) - Int(background.blue)) > 24
            }
            for x in 0...data.width {
                if x < data.width, differs(x) { if start == nil { start = x }; continue }
                if let s = start {
                    if x - s >= 3 {
                        let o = (y * data.width + (s + x - 1) / 2) * 4
                        found.append(data.bytes[o..<o + 3].map(Int.init))
                    }
                    start = nil
                }
            }
            if found.count == count { matches.append(found) }
            if found.count > best.count { best = found }
        }
        return matches.isEmpty ? best : matches[matches.count / 2]
    }

    private func assert(_ actual: [Int], equals expected: TerminalFrame.RGBColor, _ message: String,
                        file: StaticString = #filePath, line: UInt = #line) {
        for (value, wanted) in zip(actual, [expected.red, expected.green, expected.blue]) {
            XCTAssertEqual(value, Int(wanted), accuracy: 3, message, file: file, line: line)
        }
    }

    private func vt(_ color: TerminalRGBColor) -> TerminalFrame.RGBColor {
        .init(red: color.red, green: color.green, blue: color.blue)
    }
}
