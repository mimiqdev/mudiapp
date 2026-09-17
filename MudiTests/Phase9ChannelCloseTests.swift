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
