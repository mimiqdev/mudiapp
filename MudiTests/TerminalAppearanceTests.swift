import SwiftUI
import UIKit
import XCTest
@testable import Mudi

@MainActor
final class TerminalAppearanceTests: XCTestCase {
    func testTerminalViewUsesReadableColorsForLightAndDarkAppearance() {
        let terminalView = ShellTerminalView(frame: .zero)
        defer { terminalView.stop() }
        let ink = TerminalRGBColor(hex: "0A0A0A").uiColor
        let canvas = TerminalRGBColor(hex: "FAFAF7").uiColor
        let white = TerminalRGBColor(hex: "FFFFFF").uiColor

        terminalView.updateAppearance(for: .light)
        XCTAssertEqual(terminalView.backgroundColor, canvas)
        XCTAssertEqual(terminalView.nativeBackgroundColor, canvas)
        XCTAssertEqual(terminalView.nativeForegroundColor, ink)

        terminalView.updateAppearance(for: .dark)
        XCTAssertEqual(terminalView.backgroundColor, ink)
        XCTAssertEqual(terminalView.nativeBackgroundColor, ink)
        XCTAssertEqual(terminalView.nativeForegroundColor, white)
    }
}
