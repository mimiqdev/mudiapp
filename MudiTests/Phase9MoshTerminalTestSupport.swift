import Foundation
import HerdrKit
@testable import Mudi

actor TestMoshReleaseOrder {
    enum Event: Equatable, Sendable {
        case herdrReleaseSent
        case killSent
        case moshPTYClosed
    }

    private var recordedEvents: [Event] = []

    func record(_ event: Event) {
        recordedEvents.append(event)
    }

    func events() -> [Event] {
        recordedEvents
    }
}

actor TestRecordingInteractiveSSHChannel: PTYChannel,
    SSHInteractiveCommandChannel,
    SSHCommandExecutingChannel {
    private let interactiveChannel: TestMoshPTY
    private var recordedCommands: [String] = []
    private var recordedExecCommands: [String] = []
    private let releaseOrder: TestMoshReleaseOrder?
    private let execOutput: [UInt8]

    init(
        releaseOrder: TestMoshReleaseOrder? = nil,
        execOutput: [UInt8] = []
    ) {
        interactiveChannel = TestMoshPTY(releaseOrder: releaseOrder)
        self.releaseOrder = releaseOrder
        self.execOutput = execOutput
    }

    func openInteractiveCommand(
        _ command: String
    ) async throws -> any PTYOutputChannel {
        recordedCommands.append(command)
        return interactiveChannel
    }

    func execute(_ command: String) async throws -> [UInt8] {
        recordedExecCommands.append(command)
        if command.contains("kill -TERM") {
            await releaseOrder?.record(.killSent)
        }
        return execOutput
    }

    func send(_: [UInt8]) async throws {}

    func resize(columns _: Int, rows _: Int) async throws {}

    func close() async {
        await interactiveChannel.close()
    }

    func commands() -> [String] {
        recordedCommands
    }

    func execCommands() -> [String] {
        recordedExecCommands
    }

    func interactiveCommandChannel() -> TestMoshPTY {
        interactiveChannel
    }
}

actor TestRecordingMoshTransport: MoshTransportBootstrapping {
    struct Call: Sendable {
        let hostID: UUID
        let command: String?
    }

    private var calls: [Call] = []
    private var createdSessions: [SSHShellSession] = []
    private var createdPTYs: [TestMoshPTY] = []
    private let releaseOrder: TestMoshReleaseOrder?
    private var shouldFailNextAttach = false
    private var disconnectCount = 0
    private var paneDaemonPid: Int32?
    private let recordsPaneDaemonPid: Bool

    init(
        releaseOrder: TestMoshReleaseOrder? = nil,
        recordsPaneDaemonPid: Bool = true
    ) {
        self.releaseOrder = releaseOrder
        self.recordsPaneDaemonPid = recordsPaneDaemonPid
    }

    func failNextAttach() {
        shouldFailNextAttach = true
    }

    func connect(
        to host: Host,
        credentials _: SSHCredentials,
        using _: SSHShellSession,
        command: String?
    ) async throws -> SSHShellSession {
        calls.append(Call(hostID: host.id, command: command))
        if shouldFailNextAttach && command != nil {
            shouldFailNextAttach = false
            throw SSHHerdrTerminalTransportError.attachFailed
        }
        if command != nil {
            paneDaemonPid = recordsPaneDaemonPid ? 95522 : nil
        }
        let pty = TestMoshPTY(
            releaseOrder: releaseOrder,
            recordsMoshClose: true
        )
        let session = SSHShellSession(connectedChannel: pty)
        if let previousSession = createdSessions.last {
            await previousSession.disconnect()
        }
        createdSessions.append(session)
        createdPTYs.append(pty)
        return session
    }

    func connect(
        to host: Host,
        credentials: SSHCredentials,
        using bootstrapSession: SSHShellSession
    ) async throws -> SSHShellSession {
        try await connect(
            to: host,
            credentials: credentials,
            using: bootstrapSession,
            command: nil
        )
    }

    func leavePaneDaemon(using bootstrapSession: SSHShellSession) async {
        guard let pid = paneDaemonPid else { return }
        paneDaemonPid = nil
        _ = try? await bootstrapSession.execute(
            MoshServerDaemonPid.terminateCommand(pid: pid)
        )
    }

    func disconnect() async {
        disconnectCount += 1
    }

    func getCalls() -> [Call] {
        calls
    }

    func getCreatedSessions() -> [SSHShellSession] {
        createdSessions
    }

    func getCreatedPTYs() -> [TestMoshPTY] {
        createdPTYs
    }

    func getDisconnectCount() -> Int {
        disconnectCount
    }
}

/// A Sendable call counter for tests that record invocations inside a
/// @Sendable factory closure.
actor CallCounter {
    private var count = 0
    @discardableResult
    func increment() -> Int { count += 1; return count }
    func value() -> Int { count }
}

actor TestMoshPTY: PTYOutputChannel {
    private var sentBytes: [[UInt8]] = []
    private var isClosed = false
    private let releaseOrder: TestMoshReleaseOrder?
    private let recordsMoshClose: Bool
    private let output: AsyncThrowingStream<[UInt8], Error>
    private let outputContinuation: AsyncThrowingStream<[UInt8], Error>.Continuation

    init(
        releaseOrder: TestMoshReleaseOrder? = nil,
        recordsMoshClose: Bool = false
    ) {
        self.releaseOrder = releaseOrder
        self.recordsMoshClose = recordsMoshClose
        var continuation: AsyncThrowingStream<[UInt8], Error>.Continuation!
        output = AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation = $0 }
        outputContinuation = continuation
    }

    func outputStream() async -> AsyncThrowingStream<[UInt8], Error> {
        output
    }

    func send(_ bytes: [UInt8]) async throws {
        guard !isClosed else { throw SSHInteractiveCommandError.channelClosed }
        sentBytes.append(bytes)
        if String(decoding: bytes, as: UTF8.self)
            .contains("\"terminal.release\"") {
            await releaseOrder?.record(.herdrReleaseSent)
        }
    }

    func resize(columns _: Int, rows _: Int) async throws {}

    func close() async {
        isClosed = true
        if recordsMoshClose {
            await releaseOrder?.record(.moshPTYClosed)
        }
        outputContinuation.finish()
    }

    func yieldOutput(_ bytes: [UInt8]) {
        outputContinuation.yield(bytes)
    }

    func getSentBytes() -> [[UInt8]] {
        sentBytes
    }

    func getIsClosed() -> Bool {
        isClosed
    }
}
