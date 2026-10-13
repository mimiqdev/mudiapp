import GhosttyVt
import HerdrKit
import UIKit

/// Inclusive viewport cell range, normalized using real VT width/spacer
/// metadata. UIKit's preedit-document selection is deliberately separate.
struct GhosttyVTCellSelection {
    let anchor: TerminalFrame.Position
    let first: Int
    let last: Int
    let columns: Int

    init(from: TerminalFrame.Position, through: TerminalFrame.Position, screen: GhosttyVTScreen) {
        let columns = Int(screen.size.columns)
        self.columns = columns
        func endpoint(_ point: TerminalFrame.Position, trailing: Bool) -> Int {
            let row = min(Int(point.row), max(0, Int(screen.size.rows) - 1))
            var column = min(Int(point.column), max(0, columns - 1))
            let cells = screen.rows[row]?.cells ?? []
            if cells.first(where: { Int($0.column) == column })?.width == .spacerTail { column = max(0, column - 1) }
            if trailing, cells.first(where: { Int($0.column) == column })?.width == .wide { column += 1 }
            return row * columns + column
        }
        anchor = from
        let a = endpoint(from, trailing: false), b = endpoint(through, trailing: false)
        first = min(a, b)
        last = max(endpoint(from, trailing: true), endpoint(through, trailing: true))
    }

    func contains(row: Int, column: Int, width: Int = 1) -> Bool {
        let begin = row * columns + column
        return begin <= last && begin + width - 1 >= first
    }

    /// Copy text with SwiftTerm 1.15 selection semantics, decided by VT cell
    /// metadata rather than by characters: a written space (`" "`) is content,
    /// a never-written/erased cell (`""`) is padding. Each row drops only its
    /// trailing padding (interior gaps become spaces); soft-wrapped rows join
    /// without a newline and keep boundary spaces; hard rows end in `\n`;
    /// trailing all-padding rows are omitted. Spacer cells never add text,
    /// so wide chars and grapheme clusters stay whole.
    func text(in screen: GhosttyVTScreen) -> String? {
        guard columns > 0 else { return nil }
        var lines: [(text: String, hardBreak: Bool)] = []
        for rowIndex in (first / columns)...(last / columns) {
            guard screen.rows.indices.contains(rowIndex), let row = screen.rows[rowIndex] else { continue }
            var cells = row.cells.filter { $0.width != .spacerTail && $0.width != .spacerHead && contains(row: rowIndex, column: Int($0.column), width: $0.width == .wide ? 2 : 1) }
            while cells.last?.text.isEmpty == true { cells.removeLast() }
            lines.append((cells.map { $0.text.isEmpty ? " " : $0.text }.joined(), !row.isSoftWrapped))
        }
        while lines.last?.text.isEmpty == true { lines.removeLast() }
        var result = ""
        for (index, line) in lines.enumerated() {
            result += line.text
            if index < lines.count - 1, line.hardBreak { result += "\n" }
        }
        return result.isEmpty ? nil : result
    }

    static func contentMatches(_ old: GhosttyVTScreen, _ new: GhosttyVTScreen) -> Bool {
        guard old.size == new.size, old.rows.count == new.rows.count else { return false }
        for (a, b) in zip(old.rows, new.rows) {
            guard a?.isSoftWrapped == b?.isSoftWrapped, a?.cells.count == b?.cells.count else { return false }
            for (x, y) in zip(a?.cells ?? [], b?.cells ?? []) {
                guard x.column == y.column, x.width == y.width, x.text == y.text else { return false }
            }
        }
        return true
    }
}

extension GhosttyVTView: TerminalViewportInteractions {
    var selectedTerminalText: String? { terminalSelection?.text(in: screen) }

    func selectTerminalCells(from: TerminalFrame.Position, through: TerminalFrame.Position) {
        guard screen.size.columns > 0, screen.size.rows > 0 else { return }
        terminalSelection = GhosttyVTCellSelection(from: from, through: through, screen: screen)
        setNeedsDisplay()
    }

    func clearTerminalSelection() {
        terminalSelection = nil
        viewportController?.editMenu.dismissMenu()
        setNeedsDisplay()
    }

    func scrollTerminal(direction: TerminalScrollDirection, lines: Int, location: CGPoint) {
        guard lines > 0 else { return }
        clearTerminalSelection()
        if let onScroll { onScroll(direction, lines, location) }
        else { scrollLocalViewport(direction: direction, lines: lines) }
    }

    func scrollLocalViewport(direction: TerminalScrollDirection, lines: Int) {
        do {
            try terminal.scroll(to: .delta((direction == .up ? -1 : 1) * min(lines, 4096)))
            try refresh()
        } catch { onRenderError?(error) }
    }

    func selectionContains(_ cell: TerminalFrame.Cell, row: Int) -> Bool {
        terminalSelection?.contains(row: row, column: Int(cell.column), width: cell.width == .wide ? 2 : 1) == true
    }

    func viewportCell(at point: CGPoint) -> TerminalFrame.Position {
        let x = point.x.isFinite ? point.x : 0, y = point.y.isFinite ? point.y : 0
        return .init(column: UInt16(max(0, min(CGFloat(screen.size.columns - 1), floor(x / cellSize.width)))),
                     row: UInt16(max(0, min(CGFloat(screen.size.rows - 1), floor(y / cellSize.height)))))
    }
}

@MainActor
final class GhosttyVTViewportController: NSObject, UIGestureRecognizerDelegate, @preconcurrency UIEditMenuInteractionDelegate {
    weak var view: GhosttyVTView?
    lazy var editMenu = UIEditMenuInteraction(delegate: self)
    private var lastPan: CGFloat = 0

    init(view: GhosttyVTView) {
        self.view = view
        super.init()
        let select = UILongPressGestureRecognizer(target: self, action: #selector(selectText(_:)))
        select.minimumPressDuration = 0.45
        select.delegate = self
        view.addGestureRecognizer(select)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panViewport(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: self, action: #selector(focusTerminal))
        tap.delegate = self
        view.addGestureRecognizer(tap)
        view.addInteraction(editMenu)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let view, view.isInputFocusAllowed, view.markedTextRange == nil else { return false }
        if let pan = gestureRecognizer as? UIPanGestureRecognizer, view.terminalSelection == nil {
            guard view.isScrollOwnerResolved else { return false }
            if view.scrollCapability == .remoteMouseWheel,
               (try? view.terminal.status().isMouseReportingEnabled) != true { return false }
            let velocity = pan.velocity(in: view)
            return abs(velocity.y) > abs(velocity.x)
        }
        return true
    }

    @objc private func focusTerminal() {
        guard let view, view.isInputFocusAllowed, view.window != nil else { return }
        view.clearTerminalSelection()
        _ = view.becomeFirstResponder()
    }

    @objc private func selectText(_ recognizer: UILongPressGestureRecognizer) {
        guard let view else { return }
        let point = view.viewportCell(at: recognizer.location(in: view))
        switch recognizer.state {
        case .began:
            let cells = view.screen.rows[Int(point.row)]?.cells.filter { $0.width != .spacerTail && $0.width != .spacerHead } ?? []
            guard let hit = cells.firstIndex(where: { Int(point.column) >= Int($0.column) && Int(point.column) < Int($0.column) + ($0.width == .wide ? 2 : 1) }) else { return }
            func isWord(_ cell: TerminalFrame.Cell) -> Bool { !cell.text.isEmpty && !cell.text.allSatisfy(\.isWhitespace) }
            var first = hit, last = hit
            if isWord(cells[hit]) {
                while first > 0, isWord(cells[first - 1]) { first -= 1 }
                while last + 1 < cells.count, isWord(cells[last + 1]) { last += 1 }
            }
            view.selectTerminalCells(from: .init(column: cells[first].column, row: point.row),
                                     through: .init(column: cells[last].column, row: point.row))
        case .changed:
            if let selection = view.terminalSelection { view.selectTerminalCells(from: selection.anchor, through: point) }
        case .ended:
            if view.selectedTerminalText != nil {
                editMenu.presentEditMenu(with: .init(identifier: nil, sourcePoint: recognizer.location(in: view)))
            }
        case .cancelled: view.clearTerminalSelection()
        default: break
        }
    }

    @objc private func panViewport(_ recognizer: UIPanGestureRecognizer) {
        guard let view else { return }
        if let selection = view.terminalSelection {
            view.selectTerminalCells(from: selection.anchor, through: view.viewportCell(at: recognizer.location(in: view)))
            return
        }
        if recognizer.state == .began { lastPan = recognizer.translation(in: view).y }
        guard recognizer.state == .changed else { return }
        let delta = recognizer.translation(in: view).y - lastPan
        let lines = Int(abs(delta) / view.cellSize.height)
        guard lines > 0 else { return }
        lastPan += (delta > 0 ? 1 : -1) * CGFloat(lines) * view.cellSize.height
        view.scrollTerminal(direction: delta > 0 ? .up : .down, lines: lines, location: recognizer.location(in: view))
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let view else { return nil }
        var actions: [UIMenuElement] = []
        if view.selectedTerminalText != nil { actions.append(UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak view] _ in view?.copy(nil) }) }
        if view.isInputFocusAllowed, view.markedTextRange == nil, UIPasteboard.general.hasStrings {
            actions.append(UIAction(title: "Paste", image: UIImage(systemName: "doc.on.clipboard")) { [weak view] _ in view?.paste(nil) })
        }
        return UIMenu(children: actions)
    }
}
