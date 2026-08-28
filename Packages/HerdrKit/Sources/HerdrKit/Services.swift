public protocol HerdrDiscovering: Sendable {
    func snapshot(for host: Host) async throws -> HerdrSnapshot
}

public protocol TerminalTransport: Sendable {
    var kind: ActiveTransport { get }

    func connect(to host: Host) async throws
    func attach(to pane: Pane) async throws
    func send(_ bytes: [UInt8]) async throws
    func resize(columns: Int, rows: Int) async throws
    func disconnect() async
}
