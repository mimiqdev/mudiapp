import XCTest
@testable import Mudi

final class TerminalCompositionTests: XCTestCase {
    func testMarkedTextUpdatesAndClearsWhenCompositionEnds() {
        var state = TerminalCompositionState()
        XCTAssertNil(state.visibleText)

        state.update(markedText: "ni")
        XCTAssertEqual(state.visibleText, "ni")

        state.update(markedText: "nih")
        XCTAssertEqual(state.visibleText, "nih")

        state.update(markedText: nil)
        XCTAssertNil(state.visibleText)

        state.update(markedText: "中")
        state.update(markedText: "")
        XCTAssertNil(state.visibleText)
    }
}
