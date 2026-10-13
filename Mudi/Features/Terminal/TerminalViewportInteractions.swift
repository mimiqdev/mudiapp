import GhosttyVt
import HerdrKit
import UIKit

/// UIKit viewport actions. Protocol coordinates are VT rows/columns, never
/// Swift string offsets. The connected session owns the scroll destination.
@MainActor
protocol TerminalViewportInteractions: AnyObject {
    var scrollCapability: TerminalScrollCapability { get }
    var selectedTerminalText: String? { get }
    func selectTerminalCells(from: TerminalFrame.Position, through: TerminalFrame.Position)
    func clearTerminalSelection()
    func scrollTerminal(direction: TerminalScrollDirection, lines: Int, location: CGPoint)
}
