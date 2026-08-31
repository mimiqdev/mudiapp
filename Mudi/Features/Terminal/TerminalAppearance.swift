import SwiftUI
import UIKit

struct TerminalAppearance {
    let background: UIColor
    let foreground: UIColor

    static func colors(for colorScheme: ColorScheme) -> TerminalAppearance {
        if colorScheme == .dark {
            TerminalAppearance(background: .black, foreground: .white)
        } else {
            TerminalAppearance(background: .white, foreground: .black)
        }
    }
}
