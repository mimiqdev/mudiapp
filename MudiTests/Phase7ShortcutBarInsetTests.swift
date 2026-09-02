import XCTest
@testable import Mudi

/// Shortcut-bar layout reservation (review fix): the floating bar must
/// never cover terminal content. The chrome reserves the bar strip below
/// the terminal scroll view, so the grid rows are laid out only in the
/// truly visible region and `terminal.resize` receives the true visible
/// rows. These tests pin the row-arithmetic of that reservation.
@MainActor
final class Phase7ShortcutBarInsetTests: XCTestCase {
    private let cellHeight: CGFloat = 20

    func testVisibleRowsReserveBarStrip() {
        // 800pt container, 54pt reserved strip (44pt bar + 10pt margin),
        // 20pt cells: (800 - 54) / 20 = 37.4 → 37 rows.
        XCTAssertEqual(
            ShellTerminalView.visibleTerminalRows(
                containerHeight: 800,
                reservedBottom: 54,
                cellHeight: cellHeight
            ),
            37
        )
    }

    func testVisibleRowsWithoutReservationUseFullHeight() {
        XCTAssertEqual(
            ShellTerminalView.visibleTerminalRows(
                containerHeight: 800,
                reservedBottom: 0,
                cellHeight: cellHeight
            ),
            40
        )
    }

    func testKeyboardUpGrowsReservationAndShrinksRows() {
        // Keyboard down: safe-area (34) + margin (10) + bar (44).
        let keyboardDown = ShellTerminalView.visibleTerminalRows(
            containerHeight: 800,
            reservedBottom: 88,
            cellHeight: cellHeight
        )
        // Keyboard up: the riding offset grows to the keyboard height.
        let keyboardUp = ShellTerminalView.visibleTerminalRows(
            containerHeight: 800,
            reservedBottom: 300 + 44,
            cellHeight: cellHeight
        )
        XCTAssertGreaterThan(keyboardDown, keyboardUp)
        XCTAssertEqual(keyboardDown, Int((800 - 88) / cellHeight))
        XCTAssertEqual(keyboardUp, Int((800 - 344) / cellHeight))
    }

    func testVisibleRowsFloorTruncatedRows() {
        // A usable height that is not an exact cell multiple must not
        // produce a row that would render partially under the bar.
        XCTAssertEqual(
            ShellTerminalView.visibleTerminalRows(
                containerHeight: 810,
                reservedBottom: 54,
                cellHeight: cellHeight
            ),
            37,
            "(810 - 54) / 20 = 37.8 → 37 whole rows, never 38"
        )
    }

    func testVisibleRowsGuards() {
        XCTAssertEqual(
            ShellTerminalView.visibleTerminalRows(
                containerHeight: 0,
                reservedBottom: 0,
                cellHeight: cellHeight
            ),
            0
        )
        XCTAssertEqual(
            ShellTerminalView.visibleTerminalRows(
                containerHeight: 800,
                reservedBottom: 800,
                cellHeight: cellHeight
            ),
            0,
            "A full-height reservation leaves no usable rows"
        )
        XCTAssertEqual(
            ShellTerminalView.visibleTerminalRows(
                containerHeight: 800,
                reservedBottom: 54,
                cellHeight: 0
            ),
            0
        )
        XCTAssertEqual(
            ShellTerminalView.visibleTerminalRows(
                containerHeight: 800,
                reservedBottom: -1,
                cellHeight: cellHeight
            ),
            0
        )
    }
}
