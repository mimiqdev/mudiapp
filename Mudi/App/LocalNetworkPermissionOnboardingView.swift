import SwiftUI

/// First-launch surface that explains why Mudi needs local-network access
/// before the Host list is reachable, then triggers the iOS Local Network
/// authorization from the Continue action.
struct LocalNetworkPermissionOnboardingView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "wifi.router")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Local Network Access")
                .font(.title2.bold())
            VStack(alignment: .leading, spacing: 12) {
                point(
                    icon: "terminal",
                    text: "Mudi connects to your SSH and Mosh hosts directly " +
                        "over your local network — no relay server in between."
                )
                point(
                    icon: "bonjour",
                    text: "Finding Herdr sessions on your Mac also uses Bonjour discovery on the local network."
                )
                point(
                    icon: "lock.shield",
                    text: "iOS will next ask for Local Network permission. This is not " +
                        "the Location permission; denying it blocks connections to hosts on your network."
                )
            }
            .padding(.horizontal, 24)
            Spacer()
            Button {
                onContinue()
            } label: {
                Text("Continue")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            .accessibilityIdentifier("local-network-permission-continue")
            .overlay(alignment: .topLeading) {
                AccessibilityIdentifierBridge(identifier: "local-network-permission-continue", action: onContinue)
                    .frame(width: 1, height: 1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .accessibilityIdentifier("local-network-permission-onboarding")
        .overlay(alignment: .topLeading) {
            AccessibilityIdentifierBridge(identifier: "local-network-permission-onboarding")
                .frame(width: 1, height: 1)
        }
    }

    private func point(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.tint)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
