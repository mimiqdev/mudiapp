import SwiftUI

@main
struct MudiApp: App {
    init() { MudiTypography.registerFonts() }
    var body: some Scene {
        WindowGroup {
            RootView(
                localNetworkPermissionGate: SystemLocalNetworkPermissionGate()
            )
        }
    }
}
