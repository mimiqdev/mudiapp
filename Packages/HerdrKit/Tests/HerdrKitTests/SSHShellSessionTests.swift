import Foundation
import Testing
@testable import HerdrKit

private actor FakePTY: PTYChannel {
    private var receivedBytes: [UInt8] = []
    private var resizeEvents: [(columns: Int, rows: Int)] = []
    private var closeCount = 0

    func send(_ bytes: [UInt8]) async throws {
        receivedBytes.append(contentsOf: bytes)
    }

    func resize(columns: Int, rows: Int) async throws {
        resizeEvents.append((columns: columns, rows: rows))
    }

    func close() async {
        closeCount += 1
    }

    func recordedBytes() -> [UInt8] {
        receivedBytes
    }

    func lastResize() -> (columns: Int, rows: Int)? {
        resizeEvents.last
    }

    func recordedCloseCount() -> Int {
        closeCount
    }
}

private actor CredentialBox {
    private var credentials: SSHCredentials?

    func store(_ credentials: SSHCredentials) {
        self.credentials = credentials
    }

    func clear() {
        credentials = nil
    }

    func current() -> SSHCredentials? {
        credentials
    }
}

private actor CredentialReleasingPTY: PTYChannel {
    private let pty: FakePTY
    private let credentialBox: CredentialBox
    private var didClose = false

    init(pty: FakePTY, credentialBox: CredentialBox) {
        self.pty = pty
        self.credentialBox = credentialBox
    }

    func send(_ bytes: [UInt8]) async throws {
        try await pty.send(bytes)
    }

    func resize(columns: Int, rows: Int) async throws {
        try await pty.resize(columns: columns, rows: rows)
    }

    func close() async {
        guard !didClose else {
            return
        }
        didClose = true
        await pty.close()
        await credentialBox.clear()
    }
}

private actor FakeSSH: SSHClient {
    let pty: FakePTY
    let shouldFailAuthentication: Bool
    private let credentialBox = CredentialBox()
    private var connectionAttempts = 0

    init(pty: FakePTY = FakePTY(), shouldFailAuthentication: Bool = false) {
        self.pty = pty
        self.shouldFailAuthentication = shouldFailAuthentication
    }

    func connect(to _: HerdrKit.Host, credentials: SSHCredentials) async throws -> any PTYChannel {
        connectionAttempts += 1
        if shouldFailAuthentication {
            throw SSHClientError.authenticationFailed
        }
        await credentialBox.store(credentials)
        return CredentialReleasingPTY(pty: pty, credentialBox: credentialBox)
    }

    func recordedConnectionAttempts() -> Int {
        connectionAttempts
    }

    func retainedCredentials() async -> SSHCredentials? {
        await credentialBox.current()
    }
}

private actor DelayedFakeSSH: SSHClient {
    let pty: FakePTY
    private var connectionAttempts = 0
    private var connectionContinuation: CheckedContinuation<any PTYChannel, Never>?
    private var attemptWaiters: [CheckedContinuation<Void, Never>] = []

    init(pty: FakePTY) {
        self.pty = pty
    }

    func connect(to _: HerdrKit.Host, credentials _: SSHCredentials) async throws -> any PTYChannel {
        connectionAttempts += 1
        let waiters = attemptWaiters
        attemptWaiters.removeAll()
        waiters.forEach { $0.resume() }

        return await withCheckedContinuation { continuation in
            connectionContinuation = continuation
        }
    }

    func waitForFirstAttempt() async {
        if connectionAttempts > 0 {
            return
        }
        await withCheckedContinuation { continuation in
            attemptWaiters.append(continuation)
        }
    }

    func releaseConnection() {
        connectionContinuation?.resume(returning: pty)
        connectionContinuation = nil
    }

    func recordedConnectionAttempts() -> Int {
        connectionAttempts
    }
}

@Test func hostCodableRoundTripDoesNotContainCredentials() throws {
    let host = Host(
        displayName: "Desktop",
        hostname: "desktop.local",
        username: "developer"
    )

    let encoded = try JSONEncoder().encode(host)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let decoded = try JSONDecoder().decode(Host.self, from: encoded)

    #expect(decoded == host)
    #expect(!object.keys.contains("password"))
    #expect(!object.keys.contains("pemPrivateKey"))
    #expect(!object.keys.contains("pem"))
}

@Test func authenticationFailureReturnsPresentableError() async {
    let client = FakeSSH(shouldFailAuthentication: true)
    let session = SSHShellSession(client: client)
    let host = Host(displayName: "Desktop", hostname: "desktop.local", username: "developer")

    do {
        try await session.connect(
            to: host,
            credentials: SSHCredentials(password: "not-a-real-password")
        )
        Issue.record("Expected authentication to fail")
    } catch let error as SSHShellError {
        #expect(error == .authenticationFailed)
        #expect(error.errorDescription == "SSH authentication failed.")
        #expect(!error.localizedDescription.isEmpty)
    } catch {
        Issue.record("Expected a presentable SSH shell error, got: \(error)")
    }

    let attempts = await client.recordedConnectionAttempts()
    #expect(attempts == 1)
}

@Test func overlappingConnectIsRejectedAndConnectedPTYIsClosed() async throws {
    let pty = FakePTY()
    let client = DelayedFakeSSH(pty: pty)
    let session = SSHShellSession(client: client)
    let host = Host(displayName: "Desktop", hostname: "desktop.local", username: "developer")
    let credentials = SSHCredentials(password: "not-a-real-password")

    let firstConnect = Task {
        do {
            try await session.connect(to: host, credentials: credentials)
            return true
        } catch {
            return false
        }
    }
    await client.waitForFirstAttempt()

    var secondError: SSHShellError?
    do {
        try await session.connect(to: host, credentials: credentials)
        Issue.record("Expected the overlapping connection to be rejected")
    } catch let error as SSHShellError {
        secondError = error
    } catch {
        Issue.record("Expected an SSH shell error, got: \(error)")
    }

    #expect(secondError == .alreadyConnected)
    #expect(await client.recordedConnectionAttempts() == 1)

    await client.releaseConnection()
    let firstConnected = await firstConnect.value
    #expect(firstConnected)
    await session.disconnect()
    #expect(await pty.recordedCloseCount() == 1)
}

@Test func disconnectDuringConnectClosesLatePTY() async throws {
    let pty = FakePTY()
    let client = DelayedFakeSSH(pty: pty)
    let session = SSHShellSession(client: client)
    let host = Host(displayName: "Desktop", hostname: "desktop.local", username: "developer")
    let credentials = SSHCredentials(password: "not-a-real-password")

    let firstConnect = Task { () -> SSHShellError? in
        do {
            try await session.connect(to: host, credentials: credentials)
            return nil
        } catch let error as SSHShellError {
            return error
        } catch {
            return .connectionFailed
        }
    }
    await client.waitForFirstAttempt()

    await session.disconnect()
    await client.releaseConnection()

    let firstError = await firstConnect.value
    #expect(firstError == .notConnected)
    #expect(await pty.recordedCloseCount() == 1)
    #expect(await client.recordedConnectionAttempts() == 1)
}

@Test func successfulConnectSendsBytesToFakePTY() async throws {
    let pty = FakePTY()
    let client = FakeSSH(pty: pty)
    let session = SSHShellSession(client: client)
    let host = Host(displayName: "Desktop", hostname: "desktop.local", username: "developer")
    let bytes = Array("echo hello\r".utf8)

    try await session.connect(
        to: host,
        credentials: SSHCredentials(password: "not-a-real-password")
    )
    try await session.send(bytes)

    #expect(await pty.recordedBytes() == bytes)
}

@Test func resizeDeliversRowsAndColumnsToFakePTY() async throws {
    let pty = FakePTY()
    let client = FakeSSH(pty: pty)
    let session = SSHShellSession(client: client)
    let host = Host(displayName: "Desktop", hostname: "desktop.local", username: "developer")

    try await session.connect(
        to: host,
        credentials: SSHCredentials(
            pemPrivateKey: "-----BEGIN OPENSSH PRIVATE KEY-----\nfake\n-----END OPENSSH PRIVATE KEY-----"
        )
    )
    try await session.resize(columns: 120, rows: 40)

    let resize = await pty.lastResize()
    #expect(resize?.columns == 120)
    #expect(resize?.rows == 40)
}

@Test func disconnectDoesNotPersistSessionCredentials() async throws {
    let password = "session-password-\(UUID().uuidString)"
    let pem = "-----BEGIN OPENSSH PRIVATE KEY-----\n\(UUID().uuidString)\n-----END OPENSSH PRIVATE KEY-----"
    let pty = FakePTY()
    let client = FakeSSH(pty: pty)
    let session = SSHShellSession(client: client)
    let host = Host(displayName: "Desktop", hostname: "desktop.local", username: "developer")

    let credentials = SSHCredentials(password: password, pemPrivateKey: pem)
    try await session.connect(to: host, credentials: credentials)

    let retainedWhileConnected = await client.retainedCredentials()
    #expect(retainedWhileConnected == credentials)

    await session.disconnect()

    let markers = [password, pem]
    #expect(!userDefaultsContainAny(markers))

    // The following assertions cover in-memory cleanup; UserDefaults is checked above.
    let retainedAfterDisconnect = await client.retainedCredentials()
    #expect(retainedAfterDisconnect == nil)
    #expect(!valueContainsAnyMarker(session, markers: markers))
    #expect(!valueContainsAnyMarker(client, markers: markers))
    #expect(await pty.recordedCloseCount() == 1)
}

private func userDefaultsContainAny(_ markers: [String]) -> Bool {
    valueContainsAnyMarker(UserDefaults.standard.dictionaryRepresentation(), markers: markers)
}

private func valueContainsAnyMarker(_ value: Any, markers: [String], depth: Int = 0) -> Bool {
    if let string = value as? String {
        return markers.contains(where: string.contains)
    }
    if let data = value as? Data {
        return markers.contains { data.range(of: Data($0.utf8)) != nil }
    }
    if let values = value as? [Any], values.contains(where: {
        valueContainsAnyMarker($0, markers: markers, depth: depth + 1)
    }) {
        return true
    }
    if let values = value as? [String: Any], values.values.contains(where: {
        valueContainsAnyMarker($0, markers: markers, depth: depth + 1)
    }) {
        return true
    }
    guard depth < 8 else {
        return false
    }
    return Mirror(reflecting: value).children.contains {
        valueContainsAnyMarker($0.value, markers: markers, depth: depth + 1)
    }
}
