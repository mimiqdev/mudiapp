import SwiftUI

@main
struct MudiApp: App {
    var body: some Scene {
        WindowGroup {
            RootView(
                localNetworkPermissionGate: SystemLocalNetworkPermissionGate()
            )
        }
    }
}
