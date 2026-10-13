import GhosttyTerminal
import SwiftUI

@MainActor
@main
struct GhosttyTerminalHarnessApp: App {
    var body: some Scene {
        WindowGroup {
            SurfaceProbe()
        }
    }
}

@MainActor
private struct SurfaceProbe: View {
    @StateObject private var terminal = TerminalViewState()
    private let session = InMemoryTerminalSession(
        write: { _ in },
        resize: { _ in }
    )

    var body: some View {
        TerminalSurfaceView(context: terminal)
            .onAppear {
                terminal.configuration = TerminalSurfaceOptions(
                    backend: .inMemory(session)
                )
            }
    }
}
