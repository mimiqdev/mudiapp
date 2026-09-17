import Foundation
import XCTest
@testable import Mudi

@MainActor
final class Phase9NetworkRecoveryTests: XCTestCase {
    func testLiveProbeSkipsOverlayForRealInterfaceChange() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let pathMonitor = Phase9NetworkPathMonitor()
        let client = Phase2SSHClient(
            presentedFingerprint: "SHA256:phase4-test-key",
            probeSucceeds: true
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
        let originalSession = try XCTUnwrap(
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
        pathMonitor.emit(wifi)
        try await waitUntil {
            application.model.networkPathRecovery.lastPath == wifi
                && application.model.networkPathRecovery.attemptedGeneration
                    != nil
                && !application.model.networkPathRecovery.changePending
        }

        XCTAssertFalse(application.model.isTransparentlyReconnecting)
        XCTAssertIdentical(
            application.model.activeConnection?.session,
            originalSession,
            "A live bootstrap probe must keep the terminal session in place"
        )
        XCTAssertNil(application.model.errorMessage)
        let attempts = await client.connectionAttempts()
        XCTAssertEqual(
            attempts,
            1,
            "A successful path probe must not start a reconnect"
        )
    }

    func testExpensiveOnlyPathChangeDoesNotScheduleReconnect() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let pathMonitor = Phase9NetworkPathMonitor()
        let client = Phase2SSHClient(
            presentedFingerprint: "SHA256:phase4-test-key"
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
        let baseline = NetworkPathSnapshot(
            status: .satisfied,
            interfaces: [.cellular],
            isExpensive: true,
            isConstrained: false
        )
        let expensiveOnlyChange = NetworkPathSnapshot(
            status: .satisfied,
            interfaces: [.cellular],
            isExpensive: false,
            isConstrained: true
        )

        pathMonitor.emit(baseline)
        try await waitUntil {
            application.model.networkPathRecovery.lastPath == baseline
        }
        let baselineGeneration = application.model.networkPathRecovery
            .changeGeneration
        pathMonitor.emit(expensiveOnlyChange)
        try await waitUntil {
            application.model.networkPathRecovery.lastPath
                == expensiveOnlyChange
        }
        try await Task.sleep(for: .milliseconds(350))

        XCTAssertEqual(
            application.model.networkPathRecovery.changeGeneration,
            baselineGeneration,
            "Expensive/constrained-only changes are path noise"
        )
        XCTAssertFalse(application.model.networkPathRecovery.changePending)
        XCTAssertFalse(application.model.isTransparentlyReconnecting)
        let attempts = await client.connectionAttempts()
        XCTAssertEqual(attempts, 1)
    }

    func testSatisfiedInterfaceChangeStartsReconnectBeforeFullDebounce()
        async throws
    {
        let fixture = try Phase3HerdrFixtures.single()
        let reconnectGate = Phase2ConnectionGate()
        let pathMonitor = Phase9NetworkPathMonitor()
        let client = Phase2SSHClient(
            presentedFingerprint: "SHA256:phase4-test-key",
            reconnectGate: reconnectGate
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

        let changeStartedAt = ContinuousClock.now
        pathMonitor.emit(wifi)
        try await waitUntil {
            application.model.isTransparentlyReconnecting
        }
        let reconnectDelay = changeStartedAt.duration(to: ContinuousClock.now)
        XCTAssertLessThan(
            reconnectDelay,
            RootViewModel.networkPathReconnectDebounce,
            "Satisfied interface changes must not wait for the full debounce"
        )

        await reconnectGate.release()
        try await waitUntil {
            !application.model.isTransparentlyReconnecting
        }
        XCTAssertNil(application.model.errorMessage)
    }

    func testMoshPathReconnectPreservesMoshSession() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let reconnectGate = Phase2ConnectionGate()
        let pathMonitor = Phase9NetworkPathMonitor()
        let moshTransport = Phase9MoshSuccessTransport()
        let client = Phase2SSHClient(
            presentedFingerprint: "SHA256:phase4-test-key",
            reconnectGate: reconnectGate,
            probeSucceeds: true
        )
        let application = makePhase4NavigationApplication(
            fixture: fixture,
            client: client,
            moshTransport: moshTransport,
            networkPathMonitor: pathMonitor
        )
        let host = phase9Host(preferredTransport: .mosh)
        try await application.save(host)

        application.model.connect(to: host)
        try await waitUntil { application.model.activeConnection != nil }
        XCTAssertEqual(application.model.activeTransport, .mosh)
        application.model.selectOrdinaryTerminalFromPicker()
        try await waitUntil { application.model.herdrState == .ordinaryTerminal }
        let originalMoshSession = try XCTUnwrap(
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
        pathMonitor.emit(wifi)
        try await waitForConnectionAttempts(client, expected: 2)

        XCTAssertFalse(
            application.model.isTransparentlyReconnecting,
            "Mosh control-plane recovery must not show the SSH-only overlay"
        )
        XCTAssertIdentical(
            application.model.activeConnection?.session,
            originalMoshSession,
            "Mosh must remain the mounted terminal during SSH recovery"
        )
        let moshConnectCount = await moshTransport.connectCount()
        XCTAssertEqual(moshConnectCount, 1)
        let moshDisconnectCount = await moshTransport.disconnectCount()
        XCTAssertEqual(
            moshDisconnectCount,
            0,
            "Control-plane recovery must not stop Mosh"
        )

        await reconnectGate.release()
        try await waitUntil {
            application.model.networkPathRecovery.transparentTask == nil
        }
        XCTAssertFalse(application.model.isTransparentlyReconnecting)
        XCTAssertIdentical(
            application.model.activeConnection?.session,
            originalMoshSession,
            "SSH control recovery must retain the Mosh terminal session"
        )
        XCTAssertEqual(application.model.activeTransport, .mosh)
        XCTAssertEqual(application.model.herdrState, .ordinaryTerminal)
        XCTAssertNil(application.model.errorMessage)

        application.model.returnToHosts()
        try await waitUntil { !application.model.isTearingDown }
    }

    func testMoshControlPlaneFailureKeepsTerminalMounted() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let pathMonitor = Phase9NetworkPathMonitor()
        let moshTransport = Phase9MoshSuccessTransport()
        let client = Phase2SSHClient(
            presentedFingerprint: "SHA256:phase4-test-key",
            outcomes: [false, true]
        )
        let application = makePhase4NavigationApplication(
            fixture: fixture,
            client: client,
            moshTransport: moshTransport,
            networkPathMonitor: pathMonitor
        )
        let host = phase9Host(preferredTransport: .mosh)
        try await application.save(host)

        application.model.connect(to: host)
        try await waitUntil { application.model.activeConnection != nil }
        application.model.selectOrdinaryTerminalFromPicker()
        try await waitUntil { application.model.herdrState == .ordinaryTerminal }
        let originalMoshSession = try XCTUnwrap(
            application.model.activeConnection?.session
        )

        pathMonitor.emit(cellularSnapshot())
        try await waitUntil {
            application.model.networkPathRecovery.lastPath == cellularSnapshot()
        }
        pathMonitor.emit(wifiSnapshot())
        try await waitForConnectionAttempts(client, expected: 2)
        try await waitUntil {
            application.model.networkPathRecovery.transparentTask == nil
        }

        XCTAssertFalse(application.model.isTransparentlyReconnecting)
        XCTAssertIdentical(
            application.model.activeConnection?.session,
            originalMoshSession,
            "A failed SSH rebuild must not unmount the Mosh terminal"
        )
        XCTAssertEqual(application.model.activeTransport, .mosh)
        XCTAssertEqual(application.model.herdrState, .ordinaryTerminal)
        XCTAssertNil(application.model.errorMessage)
        let moshDisconnectCount = await moshTransport.disconnectCount()
        XCTAssertEqual(moshDisconnectCount, 0)

        application.model.returnToHosts()
        try await waitUntil { !application.model.isTearingDown }
    }

    func testAttachedMoshPathReconnectPreservesMoshTerminal() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let pane = try XCTUnwrap(phase4Panes(in: fixture).first)
        let reconnectGate = Phase2ConnectionGate()
        let pathMonitor = Phase9NetworkPathMonitor()
        let moshTransport = Phase9MoshSuccessTransport()
        let client = Phase2SSHClient(
            presentedFingerprint: "SHA256:phase4-test-key",
            outcomes: [false, true],
            reconnectGate: reconnectGate,
            probeSucceeds: false
        )
        let application = makePhase4NavigationApplication(
            fixture: fixture,
            client: client,
            moshTransport: moshTransport,
            networkPathMonitor: pathMonitor
        )
        let host = phase9Host(preferredTransport: .mosh)
        try await application.save(host)

        application.model.connect(to: host)
        try await waitUntil { application.model.activeConnection != nil }
        application.model.selectPane(pane.id)
        try await waitUntil {
            if case let .attached(_, attachedPane) = application.model.herdrState {
                return attachedPane.id == pane.id
            }
            return false
        }
        let originalAttachedSession = try XCTUnwrap(
            application.model.activeConnection?.session
        )

        pathMonitor.emit(cellularSnapshot())
        try await waitUntil {
            application.model.networkPathRecovery.lastPath == cellularSnapshot()
        }
        pathMonitor.emit(wifiSnapshot())

        await reconnectGate.waitUntilStarted()
        XCTAssertFalse(
            application.model.isTransparentlyReconnecting,
            "An attached Mosh pane roams over UDP and must not display reconnect overlay"
        )
        XCTAssertIdentical(
            application.model.activeConnection?.session,
            originalAttachedSession,
            "The attached terminal stays mounted during SSH recovery"
        )

        await reconnectGate.release()
        try await waitForConnectionAttempts(client, expected: 2)

        XCTAssertNotNil(application.model.activeConnection)
        XCTAssertIdentical(
            application.model.activeConnection?.session,
            originalAttachedSession,
            "Mosh session identity must be preserved across SSH rebuild failure"
        )
        XCTAssertNil(
            application.model.errorMessage,
            "A failed SSH control rebuild while Mosh is mounted must not surface an error"
        )
        guard case let .attached(_, currentPane) = application.model.herdrState else {
            return XCTFail("Attached pane state must survive SSH control failure")
        }
        XCTAssertEqual(currentPane.id, pane.id)
    }
}

private extension Phase9NetworkRecoveryTests {
    func cellularSnapshot() -> NetworkPathSnapshot {
        NetworkPathSnapshot(
            status: .satisfied,
            interfaces: [.cellular],
            isExpensive: true,
            isConstrained: false
        )
    }

    func wifiSnapshot() -> NetworkPathSnapshot {
        NetworkPathSnapshot(
            status: .satisfied,
            interfaces: [.wifi],
            isExpensive: false,
            isConstrained: false
        )
    }

    func waitForConnectionAttempts(
        _ client: Phase2SSHClient,
        expected: Int,
        timeoutSeconds: Double = 2
    ) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if await client.connectionAttempts() >= expected {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Expected at least \(expected) SSH connection attempts")
    }

    func waitUntil(
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
