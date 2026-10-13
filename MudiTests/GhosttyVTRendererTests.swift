import CoreText
import GhosttyVt
import UIKit
import XCTest
@testable import Mudi

/// No SwiftTerm parser/view or synthetic terminal frame is used here. All cells,
/// dirty states and cursor modes come from the pinned real VT binary on iOS.
@MainActor
final class GhosttyVTRendererTests: XCTestCase {
    func testFragmentedVTOutputRetainsUnicodeAndColorCells() throws {
        let view = try GhosttyVTView(configuration: .init(columns: 16, rows: 3))
        let output = Data("界e\u{301}\u{1b}[31mR\u{1b}[38;5;196mP\u{1b}[38;2;12;34;56mT\u{1b}[0m".utf8)
        // Split even UTF-8 and CSI sequences at every byte boundary.
        for byte in output {
            _ = try view.feed(Data([byte]))
        }
        let row = try XCTUnwrap(view.screen.rows[0])
        let wide = try XCTUnwrap(row.cells.first { $0.text == "界" })
        let combined = try XCTUnwrap(row.cells.first { $0.text == "e\u{301}" })
        XCTAssertEqual(wide.column, 0)
        XCTAssertEqual(wide.width, .wide)
        XCTAssertEqual(row.cells[1].width, .spacerTail)
        XCTAssertEqual(combined.column, 2)
        XCTAssertEqual(combined.width, .narrow)
        XCTAssertEqual(view.screen.text(at: 0).prefix(6), "界e\u{301}RPT ")
        XCTAssertEqual(row.cells.first { $0.text == "R" }?.style.foreground, .palette(1))
        XCTAssertEqual(row.cells.first { $0.text == "P" }?.resolvedForeground,
                       .init(red: 255, green: 0, blue: 0))
        XCTAssertEqual(row.cells.first { $0.text == "T" }?.resolvedForeground,
                       .init(red: 12, green: 34, blue: 56))
        XCTAssertEqual(view.screen.cursor?.position?.column, 6)
    }

    func testFullPartialAndCleanUpdatesRetainUnchangedRows() throws {
        let terminal = try GhosttyVt.Terminal(configuration: .init(columns: 8, rows: 4))
        var screen = GhosttyVTScreen()
        let initial = try terminal.update()
        XCTAssertEqual(initial.dirtyState, .full)
        screen.apply(initial)
        terminal.feed("first\r\nsecond\r\nthird")
        screen.apply(try terminal.update())
        let row0 = screen.rows[0]
        let row2 = screen.rows[2]
        terminal.feed("\u{1b}[2;1HX")
        let partial = try terminal.update()
        XCTAssertEqual(partial.dirtyState, .partial)
        XCTAssertTrue(partial.rows.contains { $0.index == 1 })
        XCTAssertFalse(partial.rows.contains { $0.index == 0 })
        screen.apply(partial)
        XCTAssertEqual(screen.rows[0], row0)
        XCTAssertEqual(screen.rows[2], row2)
        XCTAssertEqual(screen.text(at: 1).prefix(6), "Xecond")
        let retained = screen.rows
        let clean = try terminal.update()
        XCTAssertEqual(clean.dirtyState, .clean)
        XCTAssertTrue(clean.rows.isEmpty)
        screen.apply(clean)
        XCTAssertEqual(screen.rows, retained, "A clean incremental update is not a blank screen")
        try terminal.resize(to: .init(columns: 12, rows: 5))
        let resized = try terminal.update()
        XCTAssertEqual(resized.dirtyState, .full)
        screen.apply(resized)
        XCTAssertEqual(screen.size, .init(columns: 12, rows: 5))
        XCTAssertEqual(screen.rows.count, 5)
        XCTAssertTrue(screen.rows.allSatisfy { $0?.cells.count == 12 })
        XCTAssertEqual(screen.text(at: 0).prefix(5), "first")
    }

    func testVisibleViewportResizeIsBoundedAndPreservesModesAndContent() throws {
        let view = try GhosttyVTView(configuration: .init(columns: 20, rows: 4))
        _ = try view.feed(Data("context\u{1b}[?1h".utf8))
        var sizes: [GhosttyVt.Terminal.Size] = []
        view.onGridResize = { sizes.append($0) }
        // The view gets the already chrome-reserved viewport, not screen height.
        view.frame = CGRect(x: 0, y: 0, width: view.cellSize.width * 24 + 0.5,
                            height: view.cellSize.height * 6 + 0.5)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        XCTAssertEqual(view.screen.size, .init(columns: 24, rows: 6))
        XCTAssertEqual(sizes, [.init(columns: 24, rows: 6)])
        XCTAssertEqual(view.screen.text(at: 0).prefix(7), "context")
        XCTAssertEqual(try view.terminal.encode(.init(key: .arrowUp)), Data("\u{1b}OA".utf8))
        view.setNeedsLayout()
        view.layoutIfNeeded()
        XCTAssertEqual(sizes.count, 1, "An unchanged viewport must not churn PTY resizes")
        view.frame.size = .zero
        view.setNeedsLayout()
        view.layoutIfNeeded()
        XCTAssertEqual(view.screen.size, .init(columns: 24, rows: 6))
        XCTAssertEqual(sizes.count, 1, "Off-window/zero layout must not destroy the retained screen")

        XCTAssertNil(GhosttyVTGridGeometry.size(viewport: .zero, cell: view.cellSize))
        XCTAssertNil(GhosttyVTGridGeometry.size(viewport: CGSize(width: CGFloat.infinity, height: 1), cell: view.cellSize))
        XCTAssertNil(GhosttyVTGridGeometry.size(viewport: CGSize(width: 100, height: 100), cell: .zero))
        XCTAssertEqual(GhosttyVTGridGeometry.size(viewport: CGSize(width: 1, height: 1), cell: view.cellSize),
                       .init(columns: 1, rows: 1))
        let huge = try XCTUnwrap(GhosttyVTGridGeometry.size(
            viewport: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            cell: view.cellSize))
        XCTAssertLessThanOrEqual(huge.columns, 512)
        XCTAssertLessThanOrEqual(huge.rows, 256)
    }

    func testCoreTextDrawsVTCellsFallbackAndWideBackground() throws {
        let view = try GhosttyVTView(configuration: .init(columns: 12, rows: 2))
        view.updateFont(familyName: nil, pointSize: 22)
        _ = try view.feed(Data("\u{1b}[?25l\u{1b}[48;2;1;2;3m界\u{1b}[0me\u{301}\u{f07b}M".utf8))
        let row = try XCTUnwrap(view.screen.rows[0])
        let wide = try XCTUnwrap(row.cells.first { $0.text == "界" })
        let combined = try XCTUnwrap(row.cells.first { $0.text == "e\u{301}" })
        let nerd = try XCTUnwrap(row.cells.first { $0.text == "\u{f07b}" })
        let wideRect = try XCTUnwrap(view.glyphRect(for: wide, row: 0))
        XCTAssertEqual(wideRect.width, view.cellSize.width * 2, accuracy: 0.001)
        XCTAssertNil(view.glyphRect(for: row.cells[1], row: 0), "Spacer cells never draw a second glyph")
        XCTAssertEqual(view.glyphRect(for: combined, row: 0)?.minX, view.cellSize.width * 2)
        XCTAssertTrue(TerminalFont.hasSymbolsCascade(in: view.font))
        let line = view.glyphLine(for: nerd, foreground: .white)
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        var glyphs = [CGGlyph](repeating: 0, count: CTLineGetGlyphCount(line))
        if let run = runs.first, !glyphs.isEmpty {
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
        }
        XCTAssertFalse(glyphs.isEmpty)
        XCTAssertFalse(glyphs.contains(0), "Fallback must resolve the actual Nerd Font glyph, not .notdef")
        let image = snapshot(view)
        for cell in [wide, combined, nerd] {
            let rect = try XCTUnwrap(view.glyphRect(for: cell, row: 0))
            let pixels = try rgba(image, in: rect)
            XCTAssertGreaterThan(brightPixelCount(pixels), 8, "CoreText must paint ink for \(cell.text)")
        }
        let background = try rgba(image, in: CGRect(x: wideRect.maxX - 2, y: 1, width: 1, height: 1))
        XCTAssertEqual(Double(background[0]), 1, accuracy: 2)
        XCTAssertEqual(Double(background[1]), 2, accuracy: 2)
        XCTAssertEqual(Double(background[2]), 3, accuracy: 2)
        let attachment = XCTAttachment(image: image)
        attachment.name = "GhosttyVT-CoreText-wide-combining-Nerd"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testTrueColorAndPaletteBackgroundsAreActuallyPainted() throws {
        let view = try GhosttyVTView(configuration: .init(columns: 8, rows: 2))
        _ = try view.feed(Data("\u{1b}[?25l\u{1b}[41m \u{1b}[48;5;196m \u{1b}[48;2;12;34;56m \u{1b}[0m".utf8))
        let image = snapshot(view)
        let row = try XCTUnwrap(view.screen.rows[0])
        for cell in row.cells.prefix(3) {
            let color = try XCTUnwrap(cell.resolvedBackground)
            let pixels = try rgba(image, in: try XCTUnwrap(view.glyphRect(for: cell, row: 0)).insetBy(dx: 2, dy: 2))
            XCTAssertEqual(Double(pixels[0]), Double(color.red), accuracy: 2)
            XCTAssertEqual(Double(pixels[1]), Double(color.green), accuracy: 2)
            XCTAssertEqual(Double(pixels[2]), Double(color.blue), accuracy: 2)
        }
    }

    func testCursorHideMoveAndStylesHaveRealPixelEvidence() throws {
        let view = try GhosttyVTView(configuration: .init(columns: 8, rows: 2))
        let emptyVisible = snapshot(view)
        _ = try view.feed(Data("\u{1b}[?25l".utf8))
        let hidden = snapshot(view)
        let firstCell = CGRect(origin: .zero, size: view.cellSize)
        XCTAssertNotEqual(try rgba(emptyVisible, in: firstCell), try rgba(hidden, in: firstCell))
        _ = try view.feed(Data("\u{1b}[?25h\u{1b}[2;4H\u{1b}[6 q".utf8))
        XCTAssertEqual(view.screen.cursor?.style, .bar)
        let moved = snapshot(view)
        XCTAssertEqual(try rgba(moved, in: firstCell), try rgba(hidden, in: firstCell))
        let cursorRect = CGRect(x: view.cellSize.width * 3, y: view.cellSize.height,
                                width: view.cellSize.width, height: view.cellSize.height)
        XCTAssertNotEqual(try rgba(moved, in: cursorRect), try rgba(hidden, in: cursorRect))
    }

    func testFontResizeAndViewReattachmentDoNotResetEngine() throws {
        let view = try GhosttyVTView(configuration: .init(columns: 20, rows: 4))
        _ = try view.feed(Data("keep\u{1b}[?1h".utf8))
        let terminalIdentity = ObjectIdentifier(view.terminal)
        let window = Phase7TerminalScreenHarness.makeWindow()
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.addSubview(view)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 150)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        view.layoutIfNeeded()
        view.updateFont(familyName: TerminalFontRegistry.defaultFamilyName, pointSize: 18)
        view.layoutIfNeeded()
        view.isHidden = true
        view.removeFromSuperview()
        controller.view.addSubview(view)
        view.isHidden = false
        view.layoutIfNeeded()
        XCTAssertEqual(ObjectIdentifier(view.terminal), terminalIdentity)
        XCTAssertTrue(view.screen.rows.compactMap { $0 }.contains { row in
            row.cells.filter { $0.width != .spacerTail && $0.width != .spacerHead }.map(\.text).joined().contains("keep")
        })
        XCTAssertEqual(try view.terminal.encode(.init(key: .arrowUp)), Data("\u{1b}OA".utf8))
    }

    private func snapshot(_ view: GhosttyVTView) -> UIImage {
        view.frame.size = CGSize(width: view.cellSize.width * CGFloat(view.screen.size.columns) + 0.01,
                                 height: view.cellSize.height * CGFloat(view.screen.size.rows) + 0.01)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        view.setNeedsDisplay()
        view.layer.displayIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { context in
            view.layer.render(in: context.cgContext)
        }
    }

    private func rgba(_ image: UIImage, in rect: CGRect) throws -> [UInt8] {
        let crop = try XCTUnwrap(image.cgImage?.cropping(to: rect.integral))
        var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: crop.width, height: crop.height,
            bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        return pixels
    }

    private func brightPixelCount(_ rgba: [UInt8]) -> Int {
        stride(from: 0, to: rgba.count, by: 4).filter {
            rgba[$0] > 180 && rgba[$0 + 1] > 180 && rgba[$0 + 2] > 180
        }.count
    }
}
