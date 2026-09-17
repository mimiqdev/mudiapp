import Foundation
import HerdrKit
import XCTest
@testable import Mudi

@MainActor
final class Phase9ChannelCloseTests: XCTestCase {
    func testHungChannelCloseDoesNotPreventReconnectWithinCloseBudget()
        async throws
    {  // pi-lens-ignore: function_body_length
        let fixture = try Phase3HerdrFixtures.single()
        let pathMonitor = Phase9NetworkPathMonitor()
        let client = Phase2SSHClient(
            presentedFingerprint: "SHA256:phase4-test-key",
            hangOnFirstClose: true
        )
        let application = makePhase4NavigationApplication(
            fixture: fixture,
            client: client,
            networkPathMonitor: pathMonitor
        )
        let host = phase4Host()
        try await application.save(host)

        application.model.connect(to: host)
        try await waitUntil { application.model.activeConnection != nil }
        application.model.selectOrdinaryTerminalFromPicker()
        try await waitUntil { application.model.herdrState == .ordinaryTerminal }
        let oldSession = try XCTUnwrap(
            application.model.activeConnection?.session
        )

        let cellular = NetworkPathSnapshot(
            status: .satisfied,
            interfaces: [.cellular],
            isExpensive: true,
            isConstrained: false
        )
        let wifi = NetworkPathSnapshot(
            status: .satisfied,
            interfaces: [.wifi],
            isExpensive: false,
            isConstrained: false
        )
        pathMonitor.emit(cellular)
        try await waitUntil {
            application.model.networkPathRecovery.lastPath == cellular
        }

        let reconnectStart = ContinuousClock.now
        pathMonitor.emit(wifi)

        // Must reconnect to a new session within close budget (~1s) + connect time, NOT 60s
        try await waitUntil(timeoutSeconds: 4) {
            !application.model.isTransparentlyReconnecting
                && application.model.activeConnection?.session !== oldSession
        }
        let reconnectDuration = reconnectStart.duration(to: ContinuousClock.now)
        XCTAssertLessThan(
            reconnectDuration,
            .seconds(4),
            "Reconnect must not hang on close of dead channel"
        )
        XCTAssertNil(application.model.errorMessage)
        XCTAssertEqual(application.model.herdrState, .ordinaryTerminal)

        application.model.returnToHosts()
        try await waitUntil(timeoutSeconds: 3) { !application.model.isTearingDown }
    }

    func testReturnToHostsDuringHungCloseLeavesIsTearingDownWithinCloseBudget()
        async throws
    {  // pi-lens-ignore: function_body_length
        let fixture = try Phase3HerdrFixtures.single()
        let client = Phase2SSHClient(
            presentedFingerprint: "SHA256:phase4-test-key",
            hangOnFirstClose: true
        )
        let application = makePhase4NavigationApplication(
            fixture: fixture,
            client: client
        )
        let host = phase4Host()
        try await application.save(host)

        application.model.connect(to: host)
        try await waitUntil { application.model.activeConnection != nil }
        application.model.selectOrdinaryTerminalFromPicker()
        try await waitUntil { application.model.herdrState == .ordinaryTerminal }

        let teardownStart = ContinuousClock.now
        application.model.returnToHosts()

        try await waitUntil(timeoutSeconds: 3) {
            !application.model.isTearingDown
        }
        let teardownDuration = teardownStart.duration(to: ContinuousClock.now)
        XCTAssertLessThan(
            teardownDuration,
            .seconds(3),
            "Teardown must not wait unbounded on hung socket close"
        )
        XCTAssertNil(application.model.activeConnection)
    }

    func testReturnToHostsReleasesPaneOutsideHungSocketCloseBudget()
        async throws
    {
        let fixture = try Phase3HerdrFixtures.single()
        let pane = try XCTUnwrap(phase4Panes(in: fixture).first)
        let host = phase4Host()
        let hostFileURL = phase4HostFileURL()
        defer {
            try? FileManager.default.removeItem(
                at: hostFileURL.deletingLastPathComponent()
            )
        }
        let releaseRecorder = Phase9PaneReleaseRecorder()
        let workflow = HerdrWorkflowCoordinator(
            discovery: Phase3HerdrDiscovery(fixture: fixture),
            transport: Phase9DelayedReleaseTransport(
                delay: .seconds(1.2),
                recorder: releaseRecorder
            )
        )
        let application = makePhase4NavigationApplication(
            hostFileURL: hostFileURL,
            fixture: fixture,
            client: Phase2SSHClient(
                presentedFingerprint: "SHA256:phase4-test-key",
                hangOnFirstClose: true
            )
        )

        try await application.save(host)
        application.model.connect(to: host)
        try await waitUntil { application.model.activeConnection != nil }

        _ = try await workflow.discover(on: host)
        let attachedState = await workflow.selectPane(pane.id)
        guard case .attached = attachedState else {
            return XCTFail("Test workflow must attach the pane")
        }
        application.model.workflow = workflow
        application.model.herdrState = attachedState

        application.model.returnToHosts()

        let releaseDeadline = Date().addingTimeInterval(4)
        var didRelease = false
        while Date() < releaseDeadline {
            if await releaseRecorder.contains(pane.id) {
                didRelease = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(
            didRelease,
            "Pane release must not share the 1-second socket-close budget"
        )
        try await waitUntil(timeoutSeconds: 4) {
            !application.model.isTearingDown
        }
    }

    func testCancellationDuringHungCloseDoesNotWaitOnSocket()
        async throws
    {  // pi-lens-ignore: function_body_length
        let fixture = try Phase3HerdrFixtures.single()
        let reconnectGate = Phase2ConnectionGate()
        let pathMonitor = Phase9NetworkPathMonitor()
        let client = Phase2SSHClient(
            presentedFingerprint: "SHA256:phase4-test-key",
            reconnectGate: reconnectGate,
            hangOnFirstClose: true
        )
        let application = makePhase4NavigationApplication(
            fixture: fixture,
            client: client,
            networkPathMonitor: pathMonitor
        )
        let host = phase4Host()
        try await application.save(host)

        application.model.connect(to: host)
        try await waitUntil { application.model.activeConnection != nil }
        application.model.selectOrdinaryTerminalFromPicker()
        try await waitUntil { application.model.herdrState == .ordinaryTerminal }

        let cellular = NetworkPathSnapshot(
            status: .satisfied,
            interfaces: [.cellular],
            isExpensive: true,
            isConstrained: false
        )
        let wifi = NetworkPathSnapshot(
            status: .satisfied,
            interfaces: [.wifi],
            isExpensive: false,
            isConstrained: false
        )
        pathMonitor.emit(cellular)
        try await waitUntil {
            application.model.networkPathRecovery.lastPath == cellular
        }
        pathMonitor.emit(wifi)

        // Wait until reconnect has started and overlay is up
        try await waitUntil {
            application.model.isTransparentlyReconnecting
        }

        // Tap back during hung close
        let backStart = ContinuousClock.now
        application.model.returnToHosts()

        XCTAssertFalse(
            application.model.isTransparentlyReconnecting,
            "Overlay must clear immediately on navigation back"
        )

        // Must finish teardown within close budget without waiting for socket
        try await waitUntil(timeoutSeconds: 3) {
            !application.model.isTearingDown
        }
        let backDuration = backStart.duration(to: ContinuousClock.now)
        XCTAssertLessThan(
            backDuration,
            .seconds(3),
            "Navigation back must clear Disconnecting without waiting on socket"
        )

        await reconnectGate.release()
    }

    func testCloseTimeoutAbandonsOnlySSHBootstrapForMosh() async throws {
        let moshTransport = Phase9MoshSuccessTransport()
        let application = makeMissingPhase2Application(
            client: Phase2SSHClient(
                presentedFingerprint: "SHA256:phase9-mosh-close-timeout",
                hangOnFirstClose: true
            ),
            moshTransport: moshTransport
        )
        let host = phase9Host(preferredTransport: .mosh)
        try await application.save(host)
        _ = try await application.connect(
            to: host,
            credentials: phase2Credentials(),
            hostKeyDecision: { _ in .accept }
        )

        guard let terminalSession = await application.activeTerminalSession()
        else {
            return XCTFail("Mosh must provide a terminal data-plane session")
        }

        // Closing the SSH bootstrap is bounded, but it must not close Mosh.
        await application.disconnectBootstrapAndWait(
            preservingTerminalSession: true
        )
        await application.forceDisconnectedAfterCloseTimeout()

        let retainedSession = await application.activeTerminalSession()
        let retainedBootstrap = await application.activeShellSession()
        let retainedTransport = await application.activeTransport()
        XCTAssertNil(
            retainedBootstrap,
            "The timed-out SSH bootstrap must be abandoned"
        )
        XCTAssertIdentical(
            retainedSession,
            terminalSession,
            "A close-timeout abort must retain the Mosh terminal session"
        )
        XCTAssertEqual(
            retainedTransport,
            .mosh,
            "A close-timeout abort must retain the Mosh data plane"
        )
        let connectionState = await application.connectionState()
        let moshDisconnectCount = await moshTransport.disconnectCount()
        XCTAssertEqual(connectionState, .disconnected)
        XCTAssertEqual(moshDisconnectCount, 0)
    }

    func testTeardownCloseTimeoutDiscardsMoshWithoutRecoveryIntent() async throws {
        let moshTransport = Phase9MoshSuccessTransport()
        let application = makeMissingPhase2Application(
            client: Phase2SSHClient(
                presentedFingerprint: "SHA256:phase9-mosh-teardown"
            ),
            moshTransport: moshTransport
        )
        let host = phase9Host(preferredTransport: .mosh)
        try await application.save(host)
        _ = try await application.connect(
            to: host,
            credentials: phase2Credentials(),
            hostKeyDecision: { _ in .accept }
        )

        let initialTerminalSession = await application.activeTerminalSession()
        XCTAssertNotNil(initialTerminalSession)
        await application.forceDisconnectedAfterCloseTimeout()

        let terminalSessionAfterTimeout = await application.activeTerminalSession()
        let bootstrapAfterTimeout = await application.activeShellSession()
        let transportAfterTimeout = await application.activeTransport()
        let stateAfterTimeout = await application.connectionState()
        let moshDisconnectCount = await moshTransport.disconnectCount()
        XCTAssertNil(
            terminalSessionAfterTimeout,
            "A teardown timeout must not preserve the Mosh terminal"
        )
        XCTAssertNil(bootstrapAfterTimeout)
        XCTAssertNil(transportAfterTimeout)
        XCTAssertEqual(stateAfterTimeout, .disconnected)
        XCTAssertEqual(
            moshDisconnectCount,
            1,
            "A teardown timeout must disconnect the Mosh adapter"
        )
    }

    func testCloseTimeoutAbortDoesNotWaitForStuckMoshStop() async throws {
        let moshTransport = Phase9HangingMoshTransport()
        let application = makeMissingPhase2Application(
            client: Phase2SSHClient(
                presentedFingerprint: "SHA256:phase9-mosh-stuck-stop"
            ),
            moshTransport: moshTransport
        )
        let host = phase9Host(preferredTransport: .mosh)
        try await application.save(host)
        _ = try await application.connect(
            to: host,
            credentials: phase2Credentials(),
            hostKeyDecision: { _ in .accept }
        )

        let completion = Phase9CompletionRecorder()
        let forceTask = Task {
            await application.forceDisconnectedAfterCloseTimeout()
            await completion.markFinished()
        }
        await moshTransport.waitUntilDisconnectStarted()

        let stateAfterStart = await application.connectionState()
        let terminalSessionAfterStart = await application.activeTerminalSession()
        let transportAfterStart = await application.activeTransport()
        XCTAssertEqual(
            stateAfterStart,
            .disconnected,
            "The abort must publish disconnected before stopping a stuck Mosh adapter"
        )
        XCTAssertNil(terminalSessionAfterStart)
        XCTAssertNil(transportAfterStart)

        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline, !(await completion.isFinished()) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let forceFinished = await completion.isFinished()
        XCTAssertTrue(
            forceFinished,
            "A stuck Mosh stop must not keep the close-timeout abort suspended"
        )

        await moshTransport.releaseDisconnect()
        await forceTask.value
    }

    private func waitUntil(
        timeoutSeconds: Double = 2,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        struct ConditionTimeout: Error {}
        throw ConditionTimeout()
    }
}

private actor Phase9PaneReleaseRecorder {
    private var releasedPaneIDs: [Pane.ID] = []

    func record(_ paneID: Pane.ID) {
        releasedPaneIDs.append(paneID)
    }

    func contains(_ paneID: Pane.ID) -> Bool {
        releasedPaneIDs.contains(paneID)
    }
}

private actor Phase9DelayedReleaseTransport: TerminalTransport,
    HerdrPaneControlReleasing {
    nonisolated let kind: ActiveTransport = .ssh
    private let delay: Duration
    private let recorder: Phase9PaneReleaseRecorder

    init(delay: Duration, recorder: Phase9PaneReleaseRecorder) {
        self.delay = delay
        self.recorder = recorder
    }

    func connect(to _: Host) async throws {}

    func attach(to _: Pane) async throws {}

    func send(_: [UInt8]) async throws {}

    func resize(columns _: Int, rows _: Int) async throws {}

    func disconnect() async {}

    func releaseControl(for paneID: Pane.ID) async {
        do {
            try await Task.sleep(for: delay)
        } catch {
            return
        }
        await recorder.record(paneID)
    }
}

private actor Phase9HangingMoshTransport: MoshTransportBootstrapping {
    private let session = SSHShellSession(
        connectedChannel: Phase9HangingMoshPTY()
    )
    private var disconnectStarted = false
    private var disconnectReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func connect(
        to _: Host,
        credentials _: SSHCredentials,
        using _: SSHShellSession
    ) async throws -> SSHShellSession {
        session
    }

    func disconnect() async {
        disconnectStarted = true
        let startWaiters = self.startWaiters
        self.startWaiters.removeAll()
        startWaiters.forEach { $0.resume() }

        guard !disconnectReleased else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if disconnectReleased {
                continuation.resume()
            } else {
                releaseWaiters.append(continuation)
            }
        }
    }

    func waitUntilDisconnectStarted() async {
        guard !disconnectStarted else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if disconnectStarted {
                continuation.resume()
            } else {
                startWaiters.append(continuation)
            }
        }
    }

    func releaseDisconnect() {
        disconnectReleased = true
        let releaseWaiters = self.releaseWaiters
        self.releaseWaiters.removeAll()
        releaseWaiters.forEach { $0.resume() }
    }
}

private actor Phase9CompletionRecorder {
    private var finished = false

    func markFinished() {
        finished = true
    }

    func isFinished() -> Bool {
        finished
    }
}

private struct Phase9HangingMoshPTY: PTYChannel {
    func send(_: [UInt8]) async throws {}

    func resize(columns _: Int, rows _: Int) async throws {}

    func close() async {}
}
