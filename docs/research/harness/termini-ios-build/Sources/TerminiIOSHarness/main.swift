import SwiftUI
import Termini

@MainActor
@main
struct TerminiIOSHarnessApp: App {
    private let controller = TerminiTerminalController()

    var body: some Scene {
        WindowGroup {
            TerminiTerminalView(
                controller: controller,
                showsSystemKeyboard: false
            )
        }
    }
}
