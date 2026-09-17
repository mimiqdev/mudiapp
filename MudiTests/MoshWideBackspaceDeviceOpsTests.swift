import Foundation
import TraversioMoshCore
import XCTest
@preconcurrency import SwiftTerm
@testable import Mudi

/// Replays the exact device-log `mosh-raw` operations seq12..seq16 captured on
/// 2026-09-17T10:55 (installed build 707a6e2) into the real Traversio engine
/// and a SwiftTerm (xterm) reference, comparing the cursor, the row-13 cells
/// (including wide continuation cells and explicit foreground/background
/// attributes) and the dark-background blank blocks after EVERY operation.
///
/// The device sequence moves a per-cell software cursor block (a space with
/// explicit fg RGB(250,244,242) / bg RGB(41,36,42)) with backspaces. Device op
/// 4 (seq15) crosses wide cells: before the fork pin, Traversio's
/// `MoshTerminalScreen.previousCursorColumn()` snapped each BS to the wide
/// cell's lead column and moved two columns per BS (8 -> 4), writing the dark
/// block at the wrong column and leaving the previous block un-erased so the
/// frame accumulated multiple dark-background blanks (4 + 8, then 0 + 4 + 8)
/// while xterm kept exactly one.
///
/// Upstream mosh (`terminalfunctions.cc`, `Ctrl_BS -> move_col(-1, true)`) and
/// SwiftTerm move exactly one column. The pinned fork revision `843909f`
/// (tag `1.0.0-mudi.1`) makes `previousCursorColumn()` return
/// `max(0, cursor.column - 1)`, so this regression now asserts the engine
/// matches the xterm reference through the whole device sequence.
@MainActor
final class MoshWideBackspaceDeviceOpsTests: XCTestCase {
    private static let columns: Int32 = 47
    private static let rows: Int32 = 19
    private static let cursorRow = 13

    /// Device `mosh-raw` seq12..seq16, verbatim. The log's earlier large-screen
    /// operations are truncated in the capture, so the replay starts from a
    /// controlled matching row/cursor state (row 13, column 0, default style)
    /// instead of a full-session replay.
    private static let setup = Array("\u{1b}[14;1H".utf8)

    private static let operations: [[UInt8]] = [
        hex("e6b58be8af95e6b58be8af951b5b303b33383b323b3235303b3234343b3234323b34383b323b34313b33363b34326d20081b5b306d"),
        hex("201b5b303b33383b323b3235303b3234343b3234323b34383b323b34313b33363b34326d20081b5b306d"),
        hex("081b5b303b33383b323b3235303b3234343b3234323b34383b323b34313b33363b34326d201b5b306d200808"),
        hex("08081b5b303b33383b323b3235303b3234343b3234323b34383b323b34313b33363b34326d201b5b306d2020080808"),
        hex("08081b5b303b33383b323b3235303b3234343b3234323b34383b323b34313b33363b34326d201b5b306d2020080808"),
    ]

    func testDeviceOpsBeforeWideBackspaceMatchXtermReference() throws {
        let steps = try Self.replay(operations: Array(Self.operations.prefix(3)))
        for (index, step) in steps.enumerated() {
            XCTAssertEqual(
                step.engineCursor,
                step.referenceCursor,
                "cursor diverged after device op \(index + 1)"
            )
            XCTAssertEqual(
                step.engineRow,
                step.referenceRow,
                "row diverged after device op \(index + 1)"
            )
            XCTAssertEqual(
                step.renderedRow,
                step.engineRow,
                "renderer round trip diverged after device op \(index + 1)"
            )
        }
        XCTAssertEqual(steps.last?.engineDark, [8])
        XCTAssertEqual(steps.last?.referenceDark, [8])
    }

    func testDeviceOpsWideBackspaceMatchesXtermReference() throws {
        let steps = try Self.replay(operations: Self.operations)
        XCTAssertEqual(steps.count, 5)

        for (index, step) in steps.enumerated() {
            XCTAssertEqual(
                step.engineCursor,
                step.referenceCursor,
                "cursor diverged after device op \(index + 1)"
            )
            XCTAssertEqual(
                step.engineRow,
                step.referenceRow,
                "row diverged after device op \(index + 1)"
            )
            XCTAssertEqual(
                step.renderedRow,
                step.engineRow,
                "renderer round trip diverged after device op \(index + 1)"
            )
            XCTAssertEqual(
                step.engineDark,
                step.referenceDark,
                "dark blocks diverged after device op \(index + 1)"
            )
        }

        // The wide-cell crossings must leave exactly one dark block; keeping
        // the columns hardcoded stops a matching-wrong xterm reference (or a
        // renderer that accumulates blocks) from hiding the regression.
        XCTAssertEqual(steps[3].engineDark, [6])
        XCTAssertEqual(steps[4].engineDark, [4])
    }

    /// The pinned fork's `backspaceMovesOneColumnAtATimeAcrossWideScalars`
    /// asserts only the cursor, so backspaces that erased or rewrote the wide
    /// glyphs would not fail it. The fork checkout is immutable derived data,
    /// so the same multi-wide path is asserted here against the real engine:
    /// two move-only backspaces across `测试测试` must keep the glyphs,
    /// continuation flags and display widths, and an overwrite from the
    /// landed lead must clear the wide pair.
    func testTwoBackspacesAcrossWideScalarsPreserveGlyphsAndContinuations() throws {
        var engine = MoshTerminalScreen(
            dimensions: try MoshTerminalDimensions(columns: 12, rows: 1)
        )

        _ = try engine.apply(MoshTerminalOutput(bytes: Array("测试测试".utf8)))
        let intact = engine.snapshot
        XCTAssertEqual(intact.cursor.column, 8)

        _ = try engine.apply(MoshTerminalOutput(bytes: [0x08, 0x08]))
        XCTAssertEqual(engine.snapshot.cursor.column, 6)
        XCTAssertEqual(engine.snapshot.lineStrings, intact.lineStrings)
        XCTAssertEqual(
            engine.snapshot.rows[0].map(\.contents),
            intact.rows[0].map(\.contents)
        )
        XCTAssertEqual(
            engine.snapshot.rows[0].map(\.displayWidth),
            intact.rows[0].map(\.displayWidth)
        )
        XCTAssertEqual(
            engine.snapshot.rows[0].map(\.isContinuation),
            [false, true, false, true, false, true, false, true, false, false, false, false]
        )
        XCTAssertEqual(
            engine.snapshot.rows[0].map(\.contents),
            ["测", " ", "试", " ", "测", " ", "试", " ", " ", " ", " ", " "]
        )

        // Overwriting from the landed lead (column 6) clears the wide pair
        // before writing the space, like the fork's 中+BS+A sibling test.
        _ = try engine.apply(MoshTerminalOutput(bytes: [0x20]))
        XCTAssertEqual(engine.snapshot.cursor.column, 7)
        XCTAssertEqual(engine.snapshot.rows[0][6].contents, " ")
        XCTAssertFalse(engine.snapshot.rows[0][7].isContinuation)
        XCTAssertEqual(engine.snapshot.rows[0][7].contents, " ")
        XCTAssertEqual(engine.snapshot.rows[0][0].contents, "测")
        XCTAssertEqual(engine.snapshot.rows[0][2].contents, "试")
        XCTAssertEqual(engine.snapshot.rows[0][4].contents, "测")
        XCTAssertTrue(engine.snapshot.rows[0][5].isContinuation)
    }

    // MARK: Replay

    private struct ReplayStep {
        let engineCursor: Int
        let referenceCursor: Int
        let engineRow: [String]
        let referenceRow: [String]
        let renderedRow: [String]
        let engineDark: [Int]
        let referenceDark: [Int]
    }

    private static func replay(operations: [[UInt8]]) throws -> [ReplayStep] {
        var engine = MoshTerminalScreen(
            dimensions: try MoshTerminalDimensions(
                columns: Self.columns,
                rows: Self.rows
            )
        )
        _ = try engine.apply(MoshTerminalOutput(bytes: Self.setup))

        let reference = Terminal(
            delegate: DeviceOpsTerminalDelegate(),
            options: TerminalOptions(
                cols: Int(Self.columns),
                rows: Int(Self.rows),
                scrollback: 0
            )
        )
        reference.feed(byteArray: Self.setup)

        var rendered = Terminal(
            delegate: DeviceOpsTerminalDelegate(),
            options: TerminalOptions(
                cols: Int(Self.columns),
                rows: Int(Self.rows),
                scrollback: 0
            )
        )
        var frameRenderer = MoshScreenFrameRenderer()

        var steps: [ReplayStep] = []
        for operation in operations {
            _ = try engine.apply(MoshTerminalOutput(bytes: operation))
            reference.feed(byteArray: operation)

            let engineSnapshot = engine.snapshot
            let engineRow = Self.normalized(
                engineSnapshot.rows[Int(Self.cursorRow)]
            )
            let frame = frameRenderer.render(engineSnapshot)
            rendered.feed(byteArray: frame.bytes)

            steps.append(
                ReplayStep(
                    engineCursor: engineSnapshot.cursor.column,
                    referenceCursor: reference.buffer.x,
                    engineRow: engineRow,
                    referenceRow: Self.normalized(
                        reference,
                        row: Self.cursorRow
                    ),
                    renderedRow: Self.normalized(
                        rendered,
                        row: Self.cursorRow
                    ),
                    engineDark: Self.darkBlockColumns(
                        engineSnapshot.rows[Int(Self.cursorRow)]
                    ),
                    referenceDark: Self.darkBlockColumns(
                        reference,
                        row: Self.cursorRow
                    )
                )
            )
        }
        return steps
    }

    // MARK: Normalization

    private static func normalized(_ row: [MoshTerminalCell]) -> [String] {
        row.enumerated().map { column, cell in
            let contents: String
            if cell.isContinuation {
                contents = "C"
            } else if cell.contents == " " {
                contents = "·"
            } else {
                contents = cell.contents
            }
            return "\(column):\(contents)|w\(cell.displayWidth)|"
                + "\(colorKey(cell.attributes.foregroundColor))/"
                + "\(colorKey(cell.attributes.backgroundColor))"
        }
    }

    private static func normalized(_ terminal: Terminal, row: Int) -> [String] {
        guard let line = terminal.getLine(row: row) else { return [] }
        return (0..<terminal.cols).map { column in
            let data = line[column]
            let character = data.getCharacter()
            let contents: String
            if data.width == 0 {
                contents = "C"
            } else if character == " " || character == "\0" {
                contents = "·"
            } else {
                contents = String(character)
            }
            return "\(column):\(contents)|w\(data.width)|"
                + "\(colorKey(data.attribute.fg))/"
                + "\(colorKey(data.attribute.bg))"
        }
    }

    private static func colorKey(_ color: MoshTerminalColor?) -> String {
        switch color {
        case nil:
            return "d"
        case let .rgb(red, green, blue):
            return "rgb(\(red),\(green),\(blue))"
        case let .indexed(index):
            return "idx(\(index))"
        case let .ansi(ansi, isBright):
            return "ansi(\(ansi.rawValue),\(isBright))"
        }
    }

    private static func colorKey(_ color: SwiftTerm.Attribute.Color) -> String {
        switch color {
        case .defaultColor, .defaultInvertedColor:
            return "d"
        case let .trueColor(red, green, blue):
            return "rgb(\(red),\(green),\(blue))"
        case let .ansi256(code):
            return "idx(\(code))"
        }
    }

    /// The device's cursor block is a space with an explicit dark background
    /// (fg 250,244,242 / bg 41,36,42), not reverse video, so both forms count.
    private static func darkBlockColumns(_ row: [MoshTerminalCell]) -> [Int] {
        row.enumerated().compactMap { column, cell in
            if cell.attributes.isInverse {
                return column
            }
            if case let .rgb(red, green, blue) = cell.attributes.backgroundColor {
                return Int(red) + Int(green) + Int(blue) < 200 ? column : nil
            }
            return nil
        }
    }

    private static func darkBlockColumns(
        _ terminal: Terminal,
        row: Int
    ) -> [Int] {
        guard let line = terminal.getLine(row: row) else { return [] }
        return (0..<terminal.cols).compactMap { column in
            let data = line[column]
            if data.attribute.style.contains(.inverse) {
                return column
            }
            if case let .trueColor(red, green, blue) = data.attribute.bg {
                return Int(red) + Int(green) + Int(blue) < 200 ? column : nil
            }
            return nil
        }
    }

    private static func hex(_ string: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            bytes.append(UInt8(string[index..<next], radix: 16)!)
            index = next
        }
        return bytes
    }
}

final class DeviceOpsTerminalDelegate: TerminalDelegate {
    func send(source _: Terminal, data _: ArraySlice<UInt8>) {}
}
