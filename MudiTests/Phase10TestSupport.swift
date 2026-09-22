import Foundation
import HerdrKit
import SwiftUI
import UIKit
import XCTest
@testable import Mudi

/// Hosts the Hosts list directly so row rendering can be asserted without the
/// RootView routing: while connected the picker replaces the list entirely.
@MainActor
final class Phase10HostListHarness {
    let window: UIWindow
    let controller: UIHostingController<HostListView>

    init(_ view: HostListView) {
        window = Phase7TerminalScreenHarness.makeWindow()
        controller = UIHostingController(rootView: view)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        controller.loadViewIfNeeded()
        Phase7TerminalScreenHarness.kickAppearance(of: controller)
    }

    func close() {
        controller.view.removeFromSuperview()
        window.rootViewController = nil
        window.isHidden = true
    }

    func view(with identifier: String) -> UIView? {
        phase7View(with: identifier, in: controller.view)
    }

    func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}

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
    private let failsFirstAttempt: Bool
    private var attempts = 0

    init(
        presentedFingerprint: String = Phase10GatedSSHClient.fingerprint,
        firstConnectionGate: Phase2ConnectionGate? = nil,
        closeRecorder: Phase10ChannelCloseRecorder = Phase10ChannelCloseRecorder(),
        failsFirstAttempt: Bool = false
    ) {
        self.presentedFingerprint = presentedFingerprint
        self.firstConnectionGate = firstConnectionGate
        self.closeRecorder = closeRecorder
        self.failsFirstAttempt = failsFirstAttempt
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
        if failsFirstAttempt, attempts == 1 {
            throw ConnectionError.connectionFailed
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

/// Shared helpers for the Phase 10 suites. A base class keeps them scoped to
/// these tests instead of extending every XCTestCase in the target.
@MainActor
class Phase10TestCase: XCTestCase {
    func makePhase10Application(
        fixture: Phase3HerdrFixture,
        client: Phase10GatedSSHClient,
        moshTransport: any MoshTransportBootstrapping = Phase4MoshTransport(),
        clock: Phase10CancelThresholdClock,
        discoveryGate: Phase2ConnectionGate? = nil
    ) -> Phase4NavigationApplication {
        makePhase4NavigationApplication(
            fixture: fixture,
            client: client,
            moshTransport: moshTransport,
            connectCancelScheduler: clock,
            discoveryGate: discoveryGate
        )
    }

    func tearDownConnection(
        _ application: Phase4NavigationApplication
    ) async {
        application.model.disconnect()
        try? await waitUntil { !application.model.isTearingDown }
    }

    /// Gives MainActor continuations (including the stale-attempt paths) a
    /// chance to run before a terminal assertion.
    func settle() async throws {
        try await Task.sleep(for: .milliseconds(100))
    }

    func waitUntil(
        timeoutSeconds: Double = 3,
        line: Int = #line,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(timeoutSeconds)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        let reached = condition()
        XCTAssertTrue(reached, "Timed out (line \(line)) waiting for condition")
    }

    func waitUntilAsync(
        timeoutSeconds: Double = 3,
        line: Int = #line,
        _ condition: @escaping () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(timeoutSeconds)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        let reached = await condition()
        XCTAssertTrue(reached, "Timed out (line \(line)) waiting for async condition")
    }

    /// The harness's own lookup returns the first view carrying an
    /// identifier; SwiftUI may place it on a wrapper while the bridged
    /// UIControl carries the action. Prefer the bridged control, then fall
    /// back to accessibility activation.
    func activate(
        _ identifier: String,
        in harness: Phase7RootViewHarness
    ) -> Bool {
        let matches = phase7Descendants(of: harness.controller.view)
            .filter { $0.accessibilityIdentifier == identifier }
        for match in matches {
            if let control = match as? UIControl {
                control.sendActions(for: .touchUpInside)
                return true
            }
        }
        for match in matches where match.accessibilityActivate() {
            return true
        }
        return false
    }
}
