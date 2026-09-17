import Foundation
import TraversioMoshCore

/// The narrow Traversio `MoshSession` surface the Mosh PTY channel drives.
///
/// The protocol exists so the adapter and channel can be exercised without a
/// real UDP session. Production mounts ``TraversioMoshTerminalSession``,
/// which forwards to TraversioMoshCore's `MoshSession`.
protocol MoshTerminalSessionHandling: Sendable {
    func start() async throws
    func stop() async
    func send(_ bytes: [UInt8]) async throws
    func resize(columns: Int32, rows: Int32) async throws
    func renderOperations() async -> AsyncThrowingStream<MoshTerminalRenderOperation, Error>
    func screenSnapshot() async -> MoshTerminalScreenSnapshot
    /// Waits until the server is first heard on the UDP session, bounded by
    /// `timeout`. Throws ``MoshFirstContactError/timedOut`` when no
    /// in-sequence datagram arrives in time, so Auto mode can keep the SSH
    /// bootstrap instead of mounting a dead Mosh session.
    func waitForFirstContact(timeout: Duration) async throws
}

/// The bounded first-contact handshake did not hear the server. Classified as
/// ``MoshFailureClass/udpTimedOut`` by the transport selector.
enum MoshFirstContactError: Error, Equatable, LocalizedError, Sendable {
    case timedOut

    var errorDescription: String? {
        switch self {
        case .timedOut:
            "The Mosh server did not answer the initial UDP handshake."
        }
    }
}

/// Wraps TraversioMoshCore's `MoshSession`, which owns the encrypted UDP
/// session, SSP state, automatic link rebuild across path changes,
/// prediction, and the renderer-ready framebuffer.
actor TraversioMoshTerminalSession: MoshTerminalSessionHandling {
    /// How often the first-contact wait re-checks Traversio's connection-level
    /// liveness. Contact normally lands within one RTT; this only bounds the
    /// polling cost on a dead path.
    private static let firstContactPollInterval = Duration.milliseconds(50)

    private let session: MoshSession
    /// Consumes the session's raw host operations for the device investigation
    /// so the log carries the exact terminal bytes the engine received. The
    /// stream is only inspected while the Settings debug/save-log flags are on.
    private var hostOperationTapTask: Task<Void, Never>?
    private var rawSequence: UInt64 = 0

    init(session: MoshSession) {
        self.session = session
    }

    func start() async throws {
        try await session.start()
        self.startRawDiagnosticsTap()
    }

    func stop() async {
        self.hostOperationTapTask?.cancel()
        self.hostOperationTapTask = nil
        await session.stop()
    }

    func send(_ bytes: [UInt8]) async throws {
        guard !bytes.isEmpty else { return }
        try await session.sendKeystrokes(bytes)
    }

    func resize(columns: Int32, rows: Int32) async throws {
        try await session.resize(columns: columns, rows: rows)
    }

    func renderOperations() async -> AsyncThrowingStream<MoshTerminalRenderOperation, Error> {
        session.renderOperations
    }

    func screenSnapshot() async -> MoshTerminalScreenSnapshot {
        await session.screenSnapshot
    }

    func waitForFirstContact(timeout: Duration) async throws {
        if await hasHeardFromServer() {
            return
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            try await Task.sleep(for: Self.firstContactPollInterval)
            if await hasHeardFromServer() {
                return
            }
        }
        throw MoshFirstContactError.timedOut
    }

    /// Traversio records a connection-level last-heard timestamp only for
    /// in-sequence datagrams, so this is exact first-contact evidence rather
    /// than a socket-install guess.
    private func hasHeardFromServer() async -> Bool {
        let liveness = await session.liveness
        return liveness.lastHeardFromServerMilliseconds != nil
    }

    private func startRawDiagnosticsTap() {
        guard self.hostOperationTapTask == nil else { return }
        let stream = session.hostOperations
        self.hostOperationTapTask = Task { [weak self] in
            do {
                for try await operation in stream {
                    guard let self else { return }
                    await self.logHostOperation(operation)
                }
            } catch {
                return
            }
        }
    }

    private func logHostOperation(_ operation: MoshHostOperation) {
        let logger = DiagnosticLogger.shared
        guard logger.isDebugLoggingEnabled || logger.isSaveLogsEnabled else { return }
        self.rawSequence &+= 1
        let sequence = self.rawSequence
        switch operation {
        case let .write(output):
            logger.log(
                level: .debug,
                category: "mosh-raw",
                MoshFrameDiagnostics.rawLine(sequence: sequence, bytes: output.bytes)
            )
        case let .resize(dimensions):
            logger.log(
                level: .debug,
                category: "mosh-raw",
                "seq=\(sequence) resize=\(dimensions.columns)x\(dimensions.rows)"
            )
        case .echoAcknowledgement:
            // Too chatty and not needed for the frame investigation.
            break
        }
    }
}
