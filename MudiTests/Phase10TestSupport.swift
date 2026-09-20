import Foundation
import HerdrKit
@testable import Mudi

/// A virtual clock for the cancel-affordance threshold. Tests release the
/// parked wait explicitly, so the production 5-second contract never depends
/// on wall-clock sleeps, and they can assert exactly which duration the row
/// asked the clock for.
actor Phase10CancelThresholdClock: HostConnectingDelayScheduling {
    private var parked: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var requestedDurations: [Duration] = []

    func waitForCancelThreshold(_ duration: Duration) async throws {
        requestedDurations.append(duration)
        let id = UUID()
        try await withTaskCancellationHandler {
            if Task.isCancelled {
                throw CancellationError()
            }
            try await withCheckedThrowingContinuation { continuation in
                parked[id] = continuation
            }
        } onCancel: {
            Task { await self.resumeCancelled(id) }
        }
    }

    private func resumeCancelled(_ id: UUID) {
        parked.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    /// Moves the virtual clock past the threshold for a parked attempt. This
    /// waits for the attempt to actually reach the threshold first, so a test
    /// cannot pass by advancing the clock before the connection started.
    @discardableResult
    func releaseThresholdWait() async -> Bool {
        for _ in 0..<200 where parked.isEmpty {
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard !parked.isEmpty else { return false }
        let waiters = parked
        parked.removeAll()
        for continuation in waiters.values {
            continuation.resume()
        }
        return true
    }

    func hasParkedWait() -> Bool {
        !parked.isEmpty
    }

    func durations() -> [Duration] {
        requestedDurations
    }
}

/// Records channel closes so cancel tests can prove the retired attempt's
/// late channel was closed instead of mounted.
actor Phase10ChannelCloseRecorder {
    private var closeCountValue = 0

    func recordClose() {
        closeCountValue += 1
    }

    func closeCount() -> Int {
        closeCountValue
    }
}

private struct Phase10PTYChannel: PTYChannel, SSHCommandExecutingChannel {
    let closeRecorder: Phase10ChannelCloseRecorder

    func send(_: [UInt8]) async throws {}

    func resize(columns _: Int, rows _: Int) async throws {}

    func close() async {
        await closeRecorder.recordClose()
    }

    func execute(_: String) async throws -> [UInt8] {
        []
    }
}

/// A deterministic SSH transport double that can hold the first connection
/// open while a test asserts the row's connecting feedback, and that records
/// every channel close for the cancel half-open assertions.
actor Phase10GatedSSHClient: HostKeyAwareSSHClient {
    /// The phase-4 harness remembers this fingerprint, so the gated client
    /// never needs the host-key prompt.
    static let fingerprint = "SHA256:phase4-test-key"

    private let presentedFingerprint: String
    private let firstConnectionGate: Phase2ConnectionGate?
    private let closeRecorder: Phase10ChannelCloseRecorder
    private var attempts = 0

    init(
        presentedFingerprint: String = Phase10GatedSSHClient.fingerprint,
        firstConnectionGate: Phase2ConnectionGate? = nil,
        closeRecorder: Phase10ChannelCloseRecorder = Phase10ChannelCloseRecorder()
    ) {
        self.presentedFingerprint = presentedFingerprint
        self.firstConnectionGate = firstConnectionGate
        self.closeRecorder = closeRecorder
    }

    func connect(
        to _: Host,
        credentials _: SSHCredentials,
        hostKeyDecision: @escaping @Sendable (String) async -> HostKeyDecision
    ) async throws -> any PTYChannel {
        attempts += 1
        // The host-key decision belongs to the attempt itself: a real
        // handshake validates the key before the channel is handed over, so
        // a cancel mid-handshake cannot retroactively reject a key that was
        // already accepted. The gate below models the handshake and channel
        // setup still completing after the user cancelled.
        let decision = await hostKeyDecision(presentedFingerprint)
        guard decision == .accept else {
            throw ConnectionError.hostKeyRejected
        }
        if attempts == 1, let firstConnectionGate {
            await firstConnectionGate.markStarted()
            await firstConnectionGate.waitUntilReleased()
        }
        return Phase10PTYChannel(closeRecorder: closeRecorder)
    }

    func connectionAttempts() -> Int {
        attempts
    }
}

/// A Mosh bootstrap double that can hold the transport handshake open; its
/// returned session is closed through the same recorder so a cancelled
/// attempt cannot leave a mounted data plane behind.
actor Phase10GatedMoshTransport: MoshTransportBootstrapping {
    private let connectGate: Phase2ConnectionGate?
    private let closeRecorder: Phase10ChannelCloseRecorder
    private var connectCountValue = 0
    private var disconnectCountValue = 0

    init(
        connectGate: Phase2ConnectionGate? = nil,
        closeRecorder: Phase10ChannelCloseRecorder = Phase10ChannelCloseRecorder()
    ) {
        self.connectGate = connectGate
        self.closeRecorder = closeRecorder
    }

    func connect(
        to _: Host,
        credentials _: SSHCredentials,
        using _: SSHShellSession
    ) async throws -> SSHShellSession {
        connectCountValue += 1
        if let connectGate {
            await connectGate.markStarted()
            await connectGate.waitUntilReleased()
        }
        return SSHShellSession(
            connectedChannel: Phase10PTYChannel(closeRecorder: closeRecorder)
        )
    }

    func connect(
        to host: Host,
        credentials: SSHCredentials,
        using bootstrapSession: SSHShellSession,
        command _: String?
    ) async throws -> SSHShellSession {
        try await connect(
            to: host,
            credentials: credentials,
            using: bootstrapSession
        )
    }

    func disconnect() async {
        disconnectCountValue += 1
    }

    func connectCount() -> Int {
        connectCountValue
    }

    func disconnectCount() -> Int {
        disconnectCountValue
    }
}
