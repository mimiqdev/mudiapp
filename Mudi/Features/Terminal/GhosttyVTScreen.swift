import GhosttyVt
import UIKit

/// Owned viewport cache, not a second parser. VT updates only include dirty
/// rows; their array offsets are NOT viewport row indices.
struct GhosttyVTScreen {
    private(set) var size = GhosttyVt.Terminal.Size(columns: 0, rows: 0)
    private(set) var rows: [TerminalFrame.Row?] = []
    private(set) var theme: TerminalFrame.Theme?
    private(set) var cursor: TerminalFrame.Cursor?

    mutating func apply(_ update: TerminalFrame) {
        if update.dirtyState == .full || update.size != size {
            rows = Array(repeating: nil, count: Int(update.size.rows))
        }
        size = update.size
        theme = update.theme
        cursor = update.cursor
        for row in update.rows where Int(row.index) < rows.count {
            rows[Int(row.index)] = row
        }
        // .clean intentionally retains all rows. Cursor/theme metadata can
        // still change independently of text rows.
    }

    func text(at row: Int) -> String {
        guard rows.indices.contains(row), let row = rows[row] else { return "" }
        return row.cells.filter { $0.width != .spacerHead && $0.width != .spacerTail }
            .map { $0.text.isEmpty ? " " : $0.text }.joined()
    }
}

/// Bounds the correctness renderer's CPU/memory work before any floating-point
/// → integer conversion. A zero/off-window viewport is not a 1×1 resize.
enum GhosttyVTGridGeometry {
    static let maximumColumns: UInt16 = 512
    static let maximumRows: UInt16 = 256

    static func size(viewport: CGSize, cell: CGSize) -> GhosttyVt.Terminal.Size? {
        guard viewport.width.isFinite, viewport.height.isFinite,
              viewport.width > 0, viewport.height > 0,
              cell.width.isFinite, cell.height.isFinite,
              cell.width > 0, cell.height > 0 else { return nil }
        let columns = max(1, min(CGFloat(maximumColumns), floor(viewport.width / cell.width)))
        let rows = max(1, min(CGFloat(maximumRows), floor(viewport.height / cell.height)))
        return .init(columns: UInt16(columns), rows: UInt16(rows))
    }
}
