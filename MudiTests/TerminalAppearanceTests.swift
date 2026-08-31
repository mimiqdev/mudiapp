import SwiftUI
import UIKit
import XCTest
@testable import Mudi

@MainActor
final class TerminalAppearanceTests: XCTestCase {
    func testTerminalViewUsesReadableColorsForLightAndDarkAppearance() {
        let terminalView = ShellTerminalView(frame: .zero)

        terminalView.updateAppearance(for: .light)
        XCTAssertEqual(terminalView.backgroundColor, .white)
        XCTAssertEqual(terminalView.nativeBackgroundColor, .white)
        XCTAssertEqual(terminalView.nativeForegroundColor, .black)

        terminalView.updateAppearance(for: .dark)
        XCTAssertEqual(terminalView.backgroundColor, .black)
        XCTAssertEqual(terminalView.nativeBackgroundColor, .black)
        XCTAssertEqual(terminalView.nativeForegroundColor, .white)
    }
}
