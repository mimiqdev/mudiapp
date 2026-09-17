import TraversioMoshCore

/// One rendered frame split into the signals that must survive backpressure
/// and the display content that may be superseded.
struct MoshScreenFrame: Equatable, Sendable {
    /// BEL and OSC 1/2 title signals for this frame. ``MoshPTYChannel`` keeps
    /// an evicted frame's control bytes attached to the next delivered frame.
    let controlBytes: [UInt8]
    /// The complete display frame: a self-contained replacement.
    let frameBytes: [UInt8]

    var bytes: [UInt8] { controlBytes + frameBytes }
}

/// Paints a Traversio Mosh screen snapshot into a complete VT byte frame.
///
/// The host application owns the terminal UI, so the data-plane adapter hands
/// SwiftTerm a byte stream. Traversio's authoritative surface is a structured
/// `MoshTerminalScreenSnapshot` (cells, cursor, modes), not a byte diff, so
/// the renderer converts one snapshot into one *self-contained* frame: it
/// clears the display, repaints every cell with its attributes, then positions
/// the cursor and re-asserts the snapshot's modes.
///
/// Because each frame is a replacement rather than a diff, feeding it to the
/// terminal emulator cannot accumulate stale or duplicated glyphs across
/// roams, re-based diffs, or dropped render operations — the failure mode the
/// old restore/skip-replay byte append produced. Rendering the same snapshot
/// is idempotent.
///
/// The renderer is stateful for the signals a screen snapshot carries as
/// counters rather than as cells: it emits one BEL per bell counted since the
/// previous frame and forwards icon/window title changes as OSC sequences.
/// Per-frame state is owned by ``MoshPTYChannel``; a fresh renderer treats the
/// first snapshot as its baseline (no bell replay) and emits the current title
/// once.
///
/// Those signals are returned as ``MoshScreenFrame/controlBytes`` rather than
/// being embedded in the display frame: the channel may evict a stale display
/// frame under backpressure, and separating the two lets it re-attach an
/// evicted frame's control bytes to the next delivered frame, so a bell or
/// title is at least emitted once.
struct MoshScreenFrameRenderer {
    private var lastBellCount: UInt64?
    private var lastIconName: String?
    private var lastWindowTitle: String?

    mutating func render(_ snapshot: MoshTerminalScreenSnapshot) -> MoshScreenFrame {
        var controlBytes: [UInt8] = []
        appendBellDelta(snapshot, to: &controlBytes)
        appendTitleChanges(snapshot, to: &controlBytes)

        var bytes: [UInt8] = []
        let columns = Int(snapshot.dimensions.columns)
        let rows = Int(snapshot.dimensions.rows)
        bytes.reserveCapacity(max(0, columns * rows * 3) + 64)

        // Hide the cursor while the frame is replaced so a repaint cannot
        // flash the previous cursor position.
        appendCSI("?25l", to: &bytes)
        appendCSI("0m", to: &bytes)
        appendCSI("2J", to: &bytes)
        appendCSI("H", to: &bytes)
        appendModes(snapshot, to: &bytes)

        var activeHyperlink: MoshTerminalHyperlink?
        for (rowIndex, row) in snapshot.rows.enumerated() {
            appendCSI("\(rowIndex + 1);1H", to: &bytes)
            append(row: row, activeHyperlink: &activeHyperlink, to: &bytes)
        }
        if activeHyperlink != nil {
            appendOSC8(nil, to: &bytes)
        }

        appendCSI("0m", to: &bytes)
        let cursorRow = min(max(snapshot.cursor.row, 0), max(rows - 1, 0))
        let cursorColumn = min(max(snapshot.cursor.column, 0), max(columns - 1, 0))
        appendCSI("\(cursorRow + 1);\(cursorColumn + 1)H", to: &bytes)
        appendCSI(snapshot.isCursorVisible ? "?25h" : "?25l", to: &bytes)
        return MoshScreenFrame(
            controlBytes: controlBytes,
            frameBytes: bytes
        )
    }

    // MARK: Counter / title signals

    /// Emits one BEL per bell counted since the previous frame. The first
    /// frame only records the baseline: bells that arrived before the channel
    /// started painting are history, not a burst to replay. The delta is
    /// capped so a hostile or pathological counter cannot synthesize an
    /// unbounded frame.
    private mutating func appendBellDelta(
        _ snapshot: MoshTerminalScreenSnapshot,
        to bytes: inout [UInt8]
    ) {
        defer { lastBellCount = snapshot.bellCount }
        guard let previous = lastBellCount,
              snapshot.bellCount > previous
        else { return }
        let bellCount = Int(min(snapshot.bellCount - previous, 64))
        bytes.append(contentsOf: repeatElement(0x07, count: bellCount))
    }

    /// Forwards icon and window title changes so SwiftTerm's delegate sees the
    /// same OSC signals the old byte stream carried. The current title is
    /// emitted once when the first snapshot is painted, then only on change.
    private mutating func appendTitleChanges(
        _ snapshot: MoshTerminalScreenSnapshot,
        to bytes: inout [UInt8]
    ) {
        guard snapshot.titleInitialized else {
            lastIconName = snapshot.iconName
            lastWindowTitle = snapshot.windowTitle
            return
        }
        if lastIconName != snapshot.iconName {
            appendOSC("1;\(Self.sanitized(snapshot.iconName))", to: &bytes)
            lastIconName = snapshot.iconName
        }
        if lastWindowTitle != snapshot.windowTitle {
            appendOSC("2;\(Self.sanitized(snapshot.windowTitle))", to: &bytes)
            lastWindowTitle = snapshot.windowTitle
        }
    }

    // MARK: Frame body

    /// Repaints one row inline at the current cursor position. Trailing cells
    /// that are indistinguishable from the cleared screen are omitted so the
    /// emulator keeps null cells there (copy/trim behave like a real
    /// terminal); interior blank cells are still emitted so the cursor keeps
    /// its column. Continuation cells belong to the preceding wide cell and
    /// are skipped: feeding the wide grapheme advances the emulator by its
    /// full display width.
    private func append(
        row: [MoshTerminalCell],
        activeHyperlink: inout MoshTerminalHyperlink?,
        to bytes: inout [UInt8]
    ) {
        guard let lastMeaningfulIndex = row.lastIndex(where: { !Self.isErasable($0) }) else {
            return
        }
        var activeAttributes: MoshTerminalTextAttributes?
        for cell in row[...lastMeaningfulIndex] where !cell.isContinuation {
            if cell.hyperlink != activeHyperlink {
                appendOSC8(cell.hyperlink, to: &bytes)
                activeHyperlink = cell.hyperlink
            }
            if activeAttributes != cell.attributes {
                appendSGR(cell.attributes, to: &bytes)
                activeAttributes = cell.attributes
            }
            bytes.append(contentsOf: cell.contents.utf8)
        }
    }

    /// A cell the preceding `ESC[2J` already rendered: a plain default-colored
    /// space (or the continuation half of a wide cell).
    private static func isErasable(_ cell: MoshTerminalCell) -> Bool {
        cell.isContinuation
            || (cell.contents == " "
                && cell.attributes == .default
                && cell.hyperlink == nil)
    }

    private func appendModes(
        _ snapshot: MoshTerminalScreenSnapshot,
        to bytes: inout [UInt8]
    ) {
        appendCSI(snapshot.isApplicationCursorKeysEnabled ? "?1h" : "?1l", to: &bytes)
        appendCSI(snapshot.isReverseVideoEnabled ? "?5h" : "?5l", to: &bytes)
        appendCSI(snapshot.isBracketedPasteEnabled ? "?2004h" : "?2004l", to: &bytes)
        appendCSI(snapshot.isMouseFocusEventEnabled ? "?1004h" : "?1004l", to: &bytes)
        appendCSI(snapshot.isMouseAlternateScrollEnabled ? "?1007h" : "?1007l", to: &bytes)

        let reportingMode = Int(snapshot.mouseReportingMode.rawValue)
        let reportingModes = [9, 1000, 1001, 1002, 1003]
        // Disable every reporting mode first, then enable the active one:
        // SwiftTerm's reset handling clears its mouse mode unconditionally,
        // so an `off` emitted after the active `on` would win.
        for mode in reportingModes where mode != reportingMode {
            appendCSI("?\(mode)l", to: &bytes)
        }
        if reportingModes.contains(reportingMode) {
            appendCSI("?\(reportingMode)h", to: &bytes)
        }
        let encodingMode = Int(snapshot.mouseEncodingMode.rawValue)
        let encodingModes = [1005, 1006, 1015]
        for mode in encodingModes where mode != encodingMode {
            appendCSI("?\(mode)l", to: &bytes)
        }
        if encodingModes.contains(encodingMode) {
            appendCSI("?\(encodingMode)h", to: &bytes)
        }
    }

    private func appendSGR(
        _ attributes: MoshTerminalTextAttributes,
        to bytes: inout [UInt8]
    ) {
        var parameters = ["0"]
        if attributes.intensity == .bold {
            parameters.append("1")
        }
        if attributes.isItalic {
            parameters.append("3")
        }
        if attributes.isUnderlined {
            parameters.append("4")
        }
        if attributes.isBlinking {
            parameters.append("5")
        }
        if attributes.isInverse {
            parameters.append("7")
        }
        if attributes.isInvisible {
            parameters.append("8")
        }
        if let foreground = attributes.foregroundColor {
            parameters.append(
                contentsOf: colorParameters(
                    foreground,
                    extendedKind: 38,
                    brightBase: 90,
                    base: 30
                )
            )
        }
        if let background = attributes.backgroundColor {
            parameters.append(
                contentsOf: colorParameters(
                    background,
                    extendedKind: 48,
                    brightBase: 100,
                    base: 40
                )
            )
        }
        appendCSI("\(parameters.joined(separator: ";"))m", to: &bytes)
    }

    private func colorParameters(
        _ color: MoshTerminalColor,
        extendedKind: Int,
        brightBase: Int,
        base: Int
    ) -> [String] {
        switch color {
        case let .ansi(ansiColor, isBright):
            let ansiBase = isBright ? brightBase : base
            return ["\(ansiBase + ansiColor.rawValue)"]
        case let .indexed(index):
            return ["\(extendedKind);5;\(index)"]
        case let .rgb(red, green, blue):
            return ["\(extendedKind);2;\(red);\(green);\(blue)"]
        }
    }

    // MARK: OSC emission

    private func appendOSC8(
        _ hyperlink: MoshTerminalHyperlink?,
        to bytes: inout [UInt8]
    ) {
        guard let hyperlink else {
            appendOSC("8;;", to: &bytes)
            return
        }
        appendOSC(
            "8;\(Self.sanitized(hyperlink.parameters));\(Self.sanitized(hyperlink.url))",
            to: &bytes
        )
    }

    private func appendOSC(_ body: String, to bytes: inout [UInt8]) {
        bytes.append(0x1b)
        bytes.append(UInt8(ascii: "]"))
        bytes.append(contentsOf: body.utf8)
        bytes.append(0x1b)
        bytes.append(UInt8(ascii: "\\"))
    }

    /// Drops C0/DEL controls so server-provided title or link text cannot
    /// inject an escape sequence into the synthesized frame.
    private static func sanitized(_ value: String) -> String {
        String(value.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7f })
    }

    private func appendCSI(_ body: String, to bytes: inout [UInt8]) {
        bytes.append(0x1b)
        bytes.append(UInt8(ascii: "["))
        bytes.append(contentsOf: body.utf8)
    }
}
