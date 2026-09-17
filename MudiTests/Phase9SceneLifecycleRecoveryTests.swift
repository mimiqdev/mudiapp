import Foundation
import HerdrKit
import XCTest
@testable import Mudi

@MainActor
final class Phase9SceneLifecycleRecoveryTests: XCTestCase {
    func testPathChangeWhileSceneInactiveProbesAndReconnects() async throws {
        let reconnectGate = Phase2ConnectionGate()
        let pathMonitor = Phase9NetworkPathMonitor()
        let client = Phase2SSHClient(
            presentedFingerprint: "SHA256:phase4-test-key",
            reconnectGate: reconnectGate
        )
        let (application, oldSession) = try await makeTerminalApp(
            client: client,
            pathMonitor: pathMonitor
        )

        application.model.sceneWillResignActive()
        XCTAssertTrue(application.model.isSceneInactive)
        XCTAssertFalse(application.model.isSceneBackgrounded)

        pathMonitor.emit(cellularSnapshot())
        try await waitUntil {
            application.model.networkPathRecovery.lastPath == cellularSnapshot()
        }
        pathMonitor.emit(wifiSnapshot())

        try await waitUntil {
            application.model.isTransparentlyReconnecting
        }
        XCTAssertTrue(application.model.isSceneInactive)
        XCTAssertFalse(application.model.isSceneBackgrounded)

        await reconnectGate.release()
        try await waitUntil {
            !application.model.isTransparentlyReconnecting
                && application.model.activeConnection?.session !== oldSession
        }
        XCTAssertNil(application.model.errorMessage)
        XCTAssertEqual(application.model.herdrState, .ordinaryTerminal)

        application.model.returnToHosts()
        try await waitUntil { !application.model.isTearingDown }
    }

    func testPathChangeWhileSceneInactiveWithLiveProbeAvoidsReconnect() async throws {
        let pathMonitor = Phase9NetworkPathMonitor()
        let client = Phase2SSHClient(
            presentedFingerprint: "SHA256:phase4-test-key",
            probeSucceeds: true
        )
        let (application, originalSession) = try await makeTerminalApp(
            client: client,
            pathMonitor: pathMonitor
        )

        application.model.sceneWillResignActive()
        XCTAssertTrue(application.model.isSceneInactive)
        XCTAssertFalse(application.model.isSceneBackgrounded)

        pathMonitor.emit(cellularSnapshot())
        try await waitUntil {
            application.model.networkPathRecovery.lastPath == cellularSnapshot()
        }
        pathMonitor.emit(wifiSnapshot())
        try await waitUntil {
            application.model.networkPathRecovery.lastPath == wifiSnapshot()
                && application.model.networkPathRecovery.attemptedGeneration != nil
                && !application.model.networkPathRecovery.changePending
        }

        XCTAssertFalse(application.model.isTransparentlyReconnecting)
        XCTAssertIdentical(
            application.model.activeConnection?.session,
            originalSession,
            "A live probe in Control Center must preserve the terminal session"
        )
        XCTAssertNil(application.model.errorMessage)
        let attempts = await client.connectionAttempts()
        XCTAssertEqual(attempts, 1)

        application.model.returnToHosts()
        try await waitUntil { !application.model.isTearingDown }
    }

    func testPathChangeWhileSceneBackgroundedDefersUntilActive() async throws {
        let reconnectGate = Phase2ConnectionGate()
        let pathMonitor = Phase9NetworkPathMonitor()
        let client = Phase2SSHClient(
            presentedFingerprint: "SHA256:phase4-test-key",
            reconnectGate: reconnectGate
        )
        let (application, _) = try await makeTerminalApp(
            client: client,
            pathMonitor: pathMonitor
        )

        application.model.sceneWillResignActive()
        await application.model.sceneDidEnterBackground()
        XCTAssertTrue(application.model.isSceneBackgrounded)

        pathMonitor.emit(cellularSnapshot())
        try await waitUntil {
            application.model.networkPathRecovery.lastPath == cellularSnapshot()
        }
        pathMonitor.emit(wifiSnapshot())
        try await waitUntil {
            application.model.networkPathRecovery.lastPath == wifiSnapshot()
        }

        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(application.model.isTransparentlyReconnecting)
        XCTAssertTrue(application.model.networkPathRecovery.changePending)
        let attemptsWhileBackgrounded = await client.connectionAttempts()
        XCTAssertEqual(attemptsWhileBackgrounded, 1)

        await application.model.sceneDidBecomeActive()
        XCTAssertFalse(application.model.isSceneBackgrounded)
        XCTAssertFalse(application.model.isSceneInactive)

        try await waitUntil {
            application.model.isTransparentlyReconnecting
        }

        await reconnectGate.release()
        try await waitUntil {
            !application.model.isTransparentlyReconnecting
        }
        XCTAssertNil(application.model.errorMessage)

        application.model.returnToHosts()
        try await waitUntil { !application.model.isTearingDown }
    }
}

// MARK: - Close during inactive & Probe timeout tests

extension Phase9SceneLifecycleRecoveryTests {
    func testOrdinarySSHCloseAfterSceneWillResignActiveReconnectsOnActive() async throws {
        let reconnectGate = Phase2ConnectionGate()
        let pathMonitor = Phase9NetworkPathMonitor()
        let client = Phase2SSHClient(
            presentedFingerprint: "SHA256:phase4-test-key",
            reconnectGate: reconnectGate
        )
        let (application, oldSession) = try await makeTerminalApp(
            client: client,
            pathMonitor: pathMonitor
        )

        application.model.sceneWillResignActive()
        XCTAssertTrue(application.model.isSceneInactive)
        XCTAssertFalse(application.model.isSceneBackgrounded)

        await application.model.handleTerminalSessionClosed(
            for: ObjectIdentifier(oldSession)
        )
        XCTAssertEqual(
            application.model.pendingTerminalCloseIdentity,
            ObjectIdentifier(oldSession),
            "Close while scene is inactive must be recorded as a pending interruption"
        )
        XCTAssertFalse(
            application.model.isTransparentlyReconnecting,
            "Reconnect must not attempt while scene is inactive"
        )
        XCTAssertNotNil(
            application.model.activeConnection,
            "Terminal must remain mounted while inactive"
        )

        await reconnectGate.release()
        await application.model.sceneDidBecomeActive()

        try await waitUntil {
            application.model.activeConnection?.session !== oldSession
        }
        XCTAssertNil(application.model.pendingTerminalCloseIdentity)
        XCTAssertNil(application.model.errorMessage)
        XCTAssertEqual(application.model.herdrState, .ordinaryTerminal)

        application.model.returnToHosts()
        try await waitUntil { !application.model.isTearingDown }
    }

    func testPathProbeTimeoutPast400msLaunchesReconnect() async throws {
        let pathMonitor = Phase9NetworkPathMonitor()
        let client = Phase2SSHClient(
            presentedFingerprint: "SHA256:phase4-test-key",
            probeSucceeds: true,
            probeDelay: .milliseconds(700)
        )
        let (application, originalSession) = try await makeTerminalApp(
            client: client,
            pathMonitor: pathMonitor
        )

        pathMonitor.emit(cellularSnapshot())
        try await waitUntil {
            application.model.networkPathRecovery.lastPath == cellularSnapshot()
        }
        pathMonitor.emit(wifiSnapshot())

        // Past the 400ms probe timeout window, reconnect completes to a new session without hanging
        try await waitUntil {
            application.model.activeConnection?.session !== originalSession
        }
        XCTAssertFalse(application.model.isTransparentlyReconnecting)
        XCTAssertNil(application.model.errorMessage)
        XCTAssertEqual(application.model.herdrState, .ordinaryTerminal)

        application.model.returnToHosts()
        try await waitUntil { !application.model.isTearingDown }
    }

    private func makeTerminalApp(
        client: Phase2SSHClient,
        pathMonitor: Phase9NetworkPathMonitor
    ) async throws -> (Phase4NavigationApplication, SSHShellSession) {
        let fixture = try Phase3HerdrFixtures.single()
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
        let session = try XCTUnwrap(application.model.activeConnection?.session)
        return (application, session)
    }

    private func cellularSnapshot() -> NetworkPathSnapshot {
        NetworkPathSnapshot(
            status: .satisfied,
            interfaces: [.cellular],
            isExpensive: true,
            isConstrained: false
        )
    }

    private func wifiSnapshot() -> NetworkPathSnapshot {
        NetworkPathSnapshot(
            status: .satisfied,
            interfaces: [.wifi],
            isExpensive: false,
            isConstrained: false
        )
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        timeoutSeconds: Double = 2
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
