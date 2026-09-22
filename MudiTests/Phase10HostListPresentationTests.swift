import HerdrKit
import SwiftUI
import XCTest
@testable import Mudi

/// Phase 10: how the Hosts list presents connection state on the owning row.
/// The global banner is gone, a deliberate leave is idle, and genuine
/// failures keep the row warning and Retry.
final class Phase10HostListPresentationTests: Phase10TestCase {  // pi-lens-ignore: type_body_length
    // MARK: - Row presentation contract

    func testHostRowPresentationShowsProgressOnlyWhileConnecting() {
        let idle = HostRowConnectionPresentation.resolve(
            state: .idle,
            showsCancel: false
        )
        XCTAssertFalse(idle.isConnecting)
        XCTAssertFalse(idle.showsProgress)
        XCTAssertFalse(idle.showsCancel)
        XCTAssertTrue(idle.canConnect)

        let connecting = HostRowConnectionPresentation.resolve(
            state: .connecting,
            showsCancel: false
        )
        XCTAssertTrue(connecting.isConnecting)
        XCTAssertTrue(
            connecting.showsProgress,
            "A connecting row must render a visible progress indicator"
        )
        XCTAssertFalse(connecting.showsCancel)
        XCTAssertFalse(
            connecting.canConnect,
            "A connecting row must not start a second attempt"
        )

        let cancellable = HostRowConnectionPresentation.resolve(
            state: .connecting,
            showsCancel: true
        )
        XCTAssertTrue(cancellable.showsProgress)
        XCTAssertTrue(cancellable.showsCancel)

        let idleWithStaleCancel = HostRowConnectionPresentation.resolve(
            state: .idle,
            showsCancel: true
        )
        XCTAssertFalse(
            idleWithStaleCancel.showsCancel,
            "An idle row must never offer Cancel"
        )
    }

    /// Result states are presented by the row: connected and a genuine
    /// failure with a retry path. A deliberate leave is idle, so there is no
    /// disconnected presentation at all.
    func testHostRowPresentationCoversResultStates() {
        let connected = HostRowConnectionPresentation.resolve(
            state: .connected,
            showsCancel: false
        )
        XCTAssertTrue(connected.showsConnected)
        XCTAssertFalse(connected.showsProgress)
        XCTAssertFalse(connected.showsFailure)
        XCTAssertFalse(connected.showsRetry)
        XCTAssertFalse(
            connected.canConnect,
            "A connected row must not start another attempt"
        )

        let failed = HostRowConnectionPresentation.resolve(
            state: .failed,
            showsCancel: false
        )
        XCTAssertTrue(failed.showsFailure)
        XCTAssertTrue(
            failed.showsRetry,
            "A failed row must keep the retry affordance"
        )
        XCTAssertFalse(failed.showsProgress)
        XCTAssertFalse(failed.showsConnected)
        XCTAssertTrue(failed.canConnect)
    }

    /// Only the owning row renders the coordinator's state; every other row
    /// stays idle and connectable.
    func testRowStateIsAttributedToTheOwningHostOnly() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let owner = phase4Host()
        let other = phase4Host(hostname: "192.0.2.99")
        let client = Phase10GatedSSHClient()
        let application = makePhase10Application(
            fixture: fixture,
            client: client,
            clock: Phase10CancelThresholdClock()
        )
        try await application.save(owner)
        try await application.save(other)

        application.model.connect(to: owner)
        try await waitUntil { application.model.activeConnection != nil }
        XCTAssertEqual(
            application.model.rowConnectionState(for: owner),
            .connected
        )
        XCTAssertEqual(
            application.model.rowConnectionState(for: other),
            .idle
        )

        application.model.returnToHosts()
        try await waitUntil {
            application.model.connectionState == .disconnected
        }
        try await waitUntil { !application.model.isTearingDown }
        XCTAssertEqual(
            application.model.rowConnectionState(for: owner),
            .idle,
            "A deliberate leave must present the owner row as idle"
        )
        XCTAssertEqual(
            application.model.rowConnectionState(for: other),
            .idle
        )
        XCTAssertFalse(
            application.model.rowConnectionPresentation(for: owner).showsRetry,
            "A deliberate leave must not offer Retry"
        )
        XCTAssertFalse(
            application.model.rowConnectionPresentation(for: other).showsRetry
        )
    }
    // MARK: - Hosts-list state consolidation (no global banner)

    /// The former top banner must be gone, and every connection state must be
    /// presented by the owning Host row: connecting, connected, disconnected.
    func testHostListShowsNoGlobalBannerAndStateStaysOnTheRow()
        async throws
    {  // pi-lens-ignore: function_body_length
        let fixture = try Phase3HerdrFixtures.single()
        let host = phase4Host()
        let gate = Phase2ConnectionGate()
        let client = Phase10GatedSSHClient(firstConnectionGate: gate)
        let application = makePhase10Application(
            fixture: fixture,
            client: client,
            clock: Phase10CancelThresholdClock()
        )
        try await application.save(host)
        let harness = Phase7RootViewHarness(
            rootView: RootView(model: application.model)
        )
        defer {
            harness.close()
            Task { await gate.release() }
        }

        let hostShown = await harness.waitUntil {
            harness.view(with: "host-connect-\(host.id.uuidString)") != nil
        }
        XCTAssertTrue(hostShown)
        XCTAssertNil(
            harness.view(with: "hosts-connection-banner"),
            "The global connection banner must be removed"
        )

        XCTAssertTrue(
            activate("host-connect-\(host.id.uuidString)", in: harness)
        )
        let connectingShown = await harness.waitUntil {
            harness.view(with: "host-connecting-\(host.id.uuidString)") != nil
        }
        XCTAssertTrue(connectingShown)
        XCTAssertNil(
            harness.view(with: "hosts-connection-banner"),
            "Connecting must not bring the banner back"
        )

        await gate.release()
        try await waitUntil { application.model.activeConnection != nil }
        // RootView swaps the list for the picker while connected, so the
        // connected row contract is asserted on the model; no banner can be
        // rendered because the list is not on screen.
        XCTAssertEqual(
            application.model.rowConnectionState(for: host),
            .connected
        )
        XCTAssertTrue(
            application.model.rowConnectionPresentation(for: host)
                .showsConnected
        )

        application.model.returnToHosts()
        try await waitUntil {
            application.model.connectionState == .disconnected
        }
        try await waitUntil { !application.model.isTearingDown }
        try await settle()
        XCTAssertEqual(
            application.model.rowConnectionState(for: host),
            .idle,
            "A deliberate leave must present the row as idle"
        )
        let settledPresentation = application.model.rowConnectionPresentation(
            for: host
        )
        XCTAssertFalse(settledPresentation.showsFailure)
        XCTAssertFalse(settledPresentation.showsRetry)
        XCTAssertNil(harness.view(with: "host-failed-\(host.id.uuidString)"))
        XCTAssertNil(harness.view(with: "host-retry-\(host.id.uuidString)"))
        XCTAssertNil(
            harness.view(with: "hosts-connection-banner"),
            "A deliberate leave must not bring the banner back"
        )
    }

    /// Failure feedback and its retry path must live on the failed row, and the
    /// bottom error message must still surface the reason.
    func testFailedConnectShowsFailureAndRetryOnTheRow() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let host = phase4Host()
        let client = Phase10GatedSSHClient(failsFirstAttempt: true)
        let application = makePhase10Application(
            fixture: fixture,
            client: client,
            clock: Phase10CancelThresholdClock()
        )
        try await application.save(host)
        let harness = Phase7RootViewHarness(
            rootView: RootView(model: application.model)
        )
        defer { harness.close() }

        let hostShown = await harness.waitUntil {
            harness.view(with: "host-connect-\(host.id.uuidString)") != nil
        }
        XCTAssertTrue(hostShown)
        XCTAssertTrue(
            activate("host-connect-\(host.id.uuidString)", in: harness)
        )

        let failedShown = await harness.waitUntil {
            harness.view(with: "host-failed-\(host.id.uuidString)") != nil
        }
        XCTAssertTrue(
            failedShown,
            "A failed connect must surface on the owning row"
        )
        XCTAssertNil(
            harness.view(with: "hosts-connection-banner"),
            "Failure must not use the removed global banner"
        )
        XCTAssertNotNil(
            harness.view(with: "host-retry-\(host.id.uuidString)"),
            "The failed row must offer Retry"
        )
        XCTAssertNotNil(
            application.model.errorMessage,
            "Failure feedback must not be dropped"
        )

        XCTAssertTrue(
            activate("host-retry-\(host.id.uuidString)", in: harness)
        )
        // Retry succeeds into the picker, which replaces the list; assert the
        // recovered contract on the model and the client attempt count.
        try await waitUntil { application.model.activeConnection != nil }
        XCTAssertEqual(
            application.model.rowConnectionState(for: host),
            .connected,
            "Retry must reconnect the host"
        )
        XCTAssertFalse(
            application.model.rowConnectionPresentation(for: host).showsFailure
        )
        let attempts = await client.connectionAttempts()
        XCTAssertEqual(attempts, 2)
    }

    /// The Host list itself renders the connected indicator on the owning row
    /// (RootView replaces the list with the picker while connected).
    func testHostListRowRendersConnectedIndicatorWhenOwned() async {
        let host = phase4Host()
        let harness = Phase10HostListHarness(
            HostListView(
                hosts: [host],
                connectionState: .connected,
                connectingHostID: nil,
                stateOwnerHostID: host.id,
                showsConnectCancel: false,
                errorMessage: nil,
                onConnect: { _ in },
                onReconnect: {},
                onAdd: {},
                onEdit: { _ in },
                onDelete: { _ in }
            )
        )
        defer { harness.close() }

        let connectedShown = await harness.waitUntil {
            harness.view(with: "host-connected-\(host.id.uuidString)") != nil
        }
        XCTAssertTrue(
            connectedShown,
            "The connected row must show its state"
        )
        XCTAssertNil(
            harness.view(with: "hosts-connection-banner"),
            "The global banner must stay removed"
        )
    }

    /// A deliberate back-to-Hosts/leave is not a failure: the owning row goes
    /// back to idle with no disconnected indicator and no Retry.
    func testDeliberateLeavePresentsRowAsIdle() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let host = phase4Host()
        let client = Phase10GatedSSHClient()
        let application = makePhase10Application(
            fixture: fixture,
            client: client,
            clock: Phase10CancelThresholdClock()
        )
        try await application.save(host)
        let harness = Phase7RootViewHarness(
            rootView: RootView(model: application.model)
        )
        defer { harness.close() }

        let hostShown = await harness.waitUntil {
            harness.view(with: "host-connect-\(host.id.uuidString)") != nil
        }
        XCTAssertTrue(hostShown)
        XCTAssertTrue(
            activate("host-connect-\(host.id.uuidString)", in: harness)
        )
        try await waitUntil { application.model.activeConnection != nil }

        application.model.returnToHosts()
        try await waitUntil {
            application.model.connectionState == .disconnected
        }
        try await waitUntil { !application.model.isTearingDown }
        try await settle()

        XCTAssertEqual(
            application.model.rowConnectionState(for: host),
            .idle,
            "A deliberate leave must present the row as idle"
        )
        let presentation = application.model.rowConnectionPresentation(
            for: host
        )
        XCTAssertFalse(presentation.showsFailure)
        XCTAssertFalse(presentation.showsRetry)
        XCTAssertFalse(presentation.showsProgress)
        XCTAssertNil(harness.view(with: "host-failed-\(host.id.uuidString)"))
        XCTAssertNil(harness.view(with: "host-retry-\(host.id.uuidString)"))
        XCTAssertNil(
            harness.view(with: "host-disconnected-\(host.id.uuidString)"),
            "A deliberate leave must not add a disconnected indicator"
        )
    }

    /// A genuine network/transparent-reconnect failure still owns the row: the
    /// red warning and Retry survive the fallback to the Host list.
    func testTransparentReconnectFailurePresentsRowFailure() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let host = phase4Host()
        let application = makePhase4NavigationApplication(
            fixture: fixture,
            client: Phase2SSHClient(
                presentedFingerprint: "SHA256:phase4-test-key",
                outcomes: [false, true]
            ),
            connectCancelScheduler: Phase10CancelThresholdClock()
        )
        try await application.save(host)
        let harness = Phase7RootViewHarness(
            rootView: RootView(model: application.model)
        )
        defer { harness.close() }

        application.model.connect(to: host)
        try await waitUntil { application.model.activeConnection != nil }

        await application.transport.simulateBaseSessionDeath()
        await application.model.transparentControlPlaneReconnect(
            restoring: .rememberedPane
        )

        XCTAssertNil(application.model.activeConnection)
        XCTAssertEqual(
            application.model.errorMessage,
            RootViewModel.transparentReconnectFailureMessage
        )
        try await waitUntil { !application.model.isTearingDown }
        XCTAssertEqual(
            application.model.rowConnectionState(for: host),
            .failed,
            "A transparent-reconnect failure must keep the failure state"
        )
        let presentation = application.model.rowConnectionPresentation(
            for: host
        )
        XCTAssertTrue(presentation.showsFailure)
        XCTAssertTrue(
            presentation.showsRetry,
            "A network failure must keep the retry affordance"
        )

        let failedShown = await harness.waitUntil {
            harness.view(with: "host-failed-\(host.id.uuidString)") != nil
        }
        XCTAssertTrue(failedShown)
        XCTAssertNotNil(
            harness.view(with: "host-retry-\(host.id.uuidString)")
        )
    }

    /// A picker/control-session loss that falls back to Hosts is a failure,
    /// not a deliberate leave: the owning row keeps the red warning and Retry
    /// after the teardown.
    func testPickerSessionLostFallbackKeepsRowFailure() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let host = phase4Host()
        let application = makePhase4NavigationApplication(
            fixture: fixture,
            client: Phase2SSHClient(
                presentedFingerprint: "SHA256:phase4-test-key"
            ),
            connectCancelScheduler: Phase10CancelThresholdClock(),
            discoverySuccessesBeforeFailure: 1,
            discoveryFailures: 1
        )
        try await application.save(host)
        let harness = Phase7RootViewHarness(
            rootView: RootView(model: application.model)
        )
        defer { harness.close() }

        // The initial discovery succeeds; the picker refresh after the close
        // fails and forces the fallback to Hosts.
        application.model.connect(to: host)
        try await waitUntil {
            application.model.activeConnection != nil
                && application.model.isPanePickerPresented
        }
        let session = try XCTUnwrap(application.model.activeConnection?.session)

        await application.model.handleTerminalSessionClosed(
            for: ObjectIdentifier(session)
        )

        XCTAssertNil(application.model.activeConnection)
        XCTAssertFalse(application.model.isPanePickerPresented)
        XCTAssertNotNil(application.model.errorMessage)
        try await waitUntil { !application.model.isTearingDown }
        try await waitUntil {
            application.model.connectionState == .disconnected
        }
        XCTAssertEqual(
            application.model.rowConnectionState(for: host),
            .failed,
            "A session-lost fallback must keep the owning row failed"
        )
        let presentation = application.model.rowConnectionPresentation(
            for: host
        )
        XCTAssertTrue(presentation.showsFailure)
        XCTAssertTrue(
            presentation.showsRetry,
            "The fallback must keep the row Retry affordance"
        )
        let failedShown = await harness.waitUntil {
            harness.view(with: "host-failed-\(host.id.uuidString)") != nil
        }
        XCTAssertTrue(failedShown)
        XCTAssertNotNil(
            harness.view(with: "host-retry-\(host.id.uuidString)")
        )
    }
}
