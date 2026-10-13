import GhosttyVt

// Minimal real-engine smoke path: feed VT bytes into libghostty-vt and
// consume a Swift-owned frame. This deliberately has no UIKit renderer.
let terminal = try Terminal(configuration: .init(columns: 12, rows: 2))
terminal.feed("界 \u{1b}[38;2;12;34;56mRGB\u{1b}[0m\r\n")
let frame = try terminal.update()
precondition(frame.rows.count == 2)

let cells = frame.rows.flatMap(\.cells)
let wideCell = cells.first { $0.text == "界" }
precondition(wideCell?.width == .wide)
let rgbCell = cells.first { $0.text == "R" }
precondition(
    rgbCell?.style.foreground == .rgb(.init(red: 12, green: 34, blue: 56))
)
