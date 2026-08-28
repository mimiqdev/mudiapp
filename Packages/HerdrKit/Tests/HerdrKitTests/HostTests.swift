import Testing
@testable import HerdrKit

@Test func hostDefaultsToSSHPortAndAutomaticTransport() {
    let host = Host(
        displayName: "Desktop",
        hostname: "desktop.local",
        username: "developer"
    )

    #expect(host.port == 22)
    #expect(host.preferredTransport == .automatic)
}
