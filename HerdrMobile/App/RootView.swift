import HerdrKit
import SwiftUI

struct RootView: View {
    @State private var selectedHostID: Host.ID?
    @State private var selectedPaneID: Pane.ID?

    private let hosts = PreviewData.hosts
    private let snapshot = PreviewData.snapshot

    var body: some View {
        NavigationSplitView {
            HostListView(hosts: hosts, selection: $selectedHostID)
        } content: {
            HerdrBrowserView(snapshot: snapshot, selection: $selectedPaneID)
        } detail: {
            if let selectedPaneID {
                TerminalScreen(paneID: selectedPaneID)
            } else {
                ContentUnavailableView(
                    "Select a pane",
                    systemImage: "terminal",
                    description: Text("Choose a Herdr pane to open its terminal.")
                )
            }
        }
    }
}
