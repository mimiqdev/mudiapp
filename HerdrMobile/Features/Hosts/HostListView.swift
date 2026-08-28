import HerdrKit
import SwiftUI

struct HostListView: View {
    let hosts: [Host]
    @Binding var selection: Host.ID?

    var body: some View {
        List(hosts, selection: $selection) { host in
            VStack(alignment: .leading, spacing: 3) {
                Text(host.displayName)
                    .font(.headline)
                Text(host.hostname)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .tag(host.id)
        }
        .navigationTitle("Hosts")
        .toolbar {
            Button("Add Host", systemImage: "plus") {}
        }
    }
}
