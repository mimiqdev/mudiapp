import HerdrKit
import SwiftUI
import XCTest
@testable import Mudi

/// Phase 10, first slice: the Hosts-list connecting feedback and its cancel
/// affordance. These tests drive the production RootViewModel and RootView
/// with an injectable clock so the 5-second threshold is deterministic.
@MainActor
final class Phase10ConnectingFeedbackTests: XCTestCase {  // pi-lens-ignore: type_body_length
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

    /// Every result state is presented by the row: connected, failed with a
    /// retry path, and disconnected with a retry path.
    func testHostRowPresentationCoversResultStates() {
        let connected = HostRowConnectionPresentation.resolve(
            state: .connected,
            showsCancel: false
        )
        XCTAssertTrue(connected.showsConnected)
        XCTAssertFalse(connected.showsProgress)
        XCTAssertFalse(connected.showsFailure)
        XCTAssertFalse(connected.showsDisconnected)
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
        XCTAssertFalse(failed.showsDisconnected)
        XCTAssertTrue(failed.canConnect)

        let disconnected = HostRowConnectionPresentation.resolve(
            state: .disconnected,
            showsCancel: false
        )
        XCTAssertTrue(disconnected.showsDisconnected)
        XCTAssertTrue(
            disconnected.showsRetry,
            "A disconnected row must keep the retry affordance"
        )
        XCTAssertFalse(disconnected.showsFailure)
        XCTAssertTrue(disconnected.canConnect)
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
        XCTAssertEqual(
            application.model.rowConnectionState(for: owner),
            .disconnected
        )
        XCTAssertEqual(
            application.model.rowConnectionState(for: other),
            .idle
        )
        XCTAssertTrue(
            application.model.rowConnectionPresentation(for: owner).showsRetry
        )
        XCTAssertFalse(
            application.model.rowConnectionPresentation(for: other).showsRetry
        )
        try await waitUntil { !application.model.isTearingDown }
    }

    // MARK: - State timing

    func testConnectPublishesRowConnectingStateBeforeAnyResult() async throws {
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

        application.model.connect(to: host)

        // The attempt is gated at the SSH client, so this can only be the
        // publish-at-task-start state, not a success/failure reaction.
        XCTAssertEqual(
            application.model.rowConnectionState(for: host),
            .connecting
        )
        XCTAssertEqual(application.model.connectingHostID, host.id)
        XCTAssertTrue(
            application.model.rowConnectionPresentation(for: host)
                .showsProgress
        )
        XCTAssertFalse(application.model.showsConnectCancel)
        XCTAssertNil(application.model.errorMessage)

        await gate.release()
        try await waitUntil { application.model.activeConnection != nil }
        XCTAssertEqual(
            application.model.rowConnectionState(for: host),
            .connected,
            "A settled successful attempt shows connected on the owning row"
        )
        XCTAssertFalse(
            application.model.rowConnectionPresentation(for: host)
                .showsProgress
        )
    }

    // MARK: - Cancel threshold

    func testCancelAffordanceAppearsOnlyAfterInjectedThreshold() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let host = phase4Host()
        let gate = Phase2ConnectionGate()
        let client = Phase10GatedSSHClient(firstConnectionGate: gate)
        let clock = Phase10CancelThresholdClock()
        let application = makePhase10Application(
            fixture: fixture,
            client: client,
            clock: clock
        )
        try await application.save(host)

        application.model.connect(to: host)
        XCTAssertFalse(
            application.model.showsConnectCancel,
            "Cancel must not be offered before the threshold elapses"
        )

        let reachedThreshold = await clock.releaseThresholdWait()
        XCTAssertTrue(
            reachedThreshold,
            "The connecting row must park a threshold wait"
        )
        try await waitUntil { application.model.showsConnectCancel }
        let presentation = application.model.rowConnectionPresentation(
            for: host
        )
        XCTAssertTrue(presentation.showsCancel)
        XCTAssertTrue(presentation.showsProgress)

        let durations = await clock.durations()
        XCTAssertEqual(
            durations,
            [.seconds(5)],
            "The default cancel threshold must be 5 seconds"
        )

        await gate.release()
        try await waitUntil { application.model.activeConnection != nil }
        XCTAssertFalse(application.model.showsConnectCancel)
    }

    func testConnectionWithinThresholdNeverShowsCancel() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let host = phase4Host()
        let gate = Phase2ConnectionGate()
        let client = Phase10GatedSSHClient(firstConnectionGate: gate)
        let clock = Phase10CancelThresholdClock()
        let application = makePhase10Application(
            fixture: fixture,
            client: client,
            clock: clock
        )
        try await application.save(host)

        application.model.connect(to: host)
        try await waitUntilAsync { await clock.hasParkedWait() }

        await gate.release()
        try await waitUntil { application.model.activeConnection != nil }

        XCTAssertFalse(application.model.showsConnectCancel)
        XCTAssertEqual(
            application.model.rowConnectionState(for: host),
            .connected
        )
        // The threshold wait must be retired with the attempt, so the clock
        // cannot flip a settled row back into a cancellable state.
        try await waitUntilAsync { await clock.hasParkedWait() == false }
        let releasedLate = await clock.releaseThresholdWait()
        XCTAssertFalse(releasedLate)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(application.model.showsConnectCancel)
    }

    // MARK: - Cancel at each connection stage

    func testCancelDuringSSHBootstrapReturnsRowToIdleAndClosesLateChannel()
        async throws
    {  // pi-lens-ignore: function_body_length
        let fixture = try Phase3HerdrFixtures.single()
        let host = phase4Host()
        let gate = Phase2ConnectionGate()
        let closeRecorder = Phase10ChannelCloseRecorder()
        let client = Phase10GatedSSHClient(
            firstConnectionGate: gate,
            closeRecorder: closeRecorder
        )
        let clock = Phase10CancelThresholdClock()
        let application = makePhase10Application(
            fixture: fixture,
            client: client,
            clock: clock
        )
        try await application.save(host)

        application.model.connect(to: host)
        try await waitUntilAsync { await clock.releaseThresholdWait() }
        try await waitUntil { application.model.showsConnectCancel }

        application.model.cancelConnect()

        XCTAssertEqual(
            application.model.rowConnectionState(for: host),
            .idle
        )
        XCTAssertFalse(application.model.showsConnectCancel)
        XCTAssertNil(application.model.errorMessage)
        try await waitUntilAsync {
            await application.coordinator.connectionState() == .idle
        }
        XCTAssertEqual(application.model.connectionState, .idle)
        let attemptsBeforeRelease = await client.connectionAttempts()
        XCTAssertEqual(attemptsBeforeRelease, 1)
        let closesBeforeRelease = await closeRecorder.closeCount()
        XCTAssertEqual(closesBeforeRelease, 0)

        // The retired attempt's late channel must be rejected by attempt ID
        // and closed, never mounted.
        await gate.release()
        try await waitUntilAsync { await closeRecorder.closeCount() == 1 }
        XCTAssertNil(application.model.activeConnection)
        let shellSession = await application.coordinator.activeShellSession()
        XCTAssertNil(shellSession)
        try await settle()
        XCTAssertEqual(application.model.connectionState, .idle)

        // An immediate retry uses the same host row and succeeds.
        application.model.connect(to: host)
        try await waitUntil { application.model.activeConnection != nil }
        let retryAttempts = await client.connectionAttempts()
        XCTAssertEqual(retryAttempts, 2)
        XCTAssertEqual(application.model.connectionState, .connected)
        await tearDownConnection(application)
    }

    func testCancelDuringMoshBootstrapStopsTransportAndRetrySucceeds()
        async throws
    {  // pi-lens-ignore: function_body_length
        let fixture = try Phase3HerdrFixtures.single()
        let host = phase4Host()
        let moshHost = Host(
            id: host.id,
            displayName: host.displayName,
            hostname: host.hostname,
            port: host.port,
            username: host.username,
            preferredTransport: .mosh
        )
        let gate = Phase2ConnectionGate()
        let closeRecorder = Phase10ChannelCloseRecorder()
        let client = Phase10GatedSSHClient()
        let moshTransport = Phase10GatedMoshTransport(
            connectGate: gate,
            closeRecorder: closeRecorder
        )
        let clock = Phase10CancelThresholdClock()
        let application = makePhase10Application(
            fixture: fixture,
            client: client,
            moshTransport: moshTransport,
            clock: clock
        )
        try await application.save(moshHost)

        application.model.connect(to: moshHost)
        try await waitUntilAsync { await gate.hasStarted() }
        try await waitUntilAsync { await clock.releaseThresholdWait() }
        try await waitUntil { application.model.showsConnectCancel }

        application.model.cancelConnect()

        XCTAssertEqual(
            application.model.rowConnectionState(for: moshHost),
            .idle
        )
        try await waitUntilAsync {
            await moshTransport.disconnectCount() >= 1
        }
        XCTAssertNil(application.model.activeConnection)

        // The gated Mosh handshake returns a session after the cancel; it
        // must be stopped instead of being mounted as the terminal.
        await gate.release()
        try await waitUntilAsync { await closeRecorder.closeCount() == 1 }
        XCTAssertNil(application.model.activeConnection)
        try await settle()
        XCTAssertEqual(application.model.connectionState, .idle)
        XCTAssertNil(application.model.errorMessage)

        application.model.connect(to: moshHost)
        try await waitUntil { application.model.activeConnection != nil }
        XCTAssertEqual(application.model.activeTransport, .mosh)
        XCTAssertEqual(
            application.model.rowConnectionState(for: moshHost),
            .connected
        )
        let moshAttempts = await moshTransport.connectCount()
        XCTAssertEqual(
            moshAttempts,
            2,
            "The retry must open a fresh Mosh bootstrap"
        )
        await tearDownConnection(application)
    }

    func testCancelDuringHerdrDiscoveryCleansUpSessionAndAllowsRetry()
        async throws
    {  // pi-lens-ignore: function_body_length
        let fixture = try Phase3HerdrFixtures.single()
        let host = phase4Host()
        let discoveryGate = Phase2ConnectionGate()
        let closeRecorder = Phase10ChannelCloseRecorder()
        let client = Phase10GatedSSHClient(closeRecorder: closeRecorder)
        let clock = Phase10CancelThresholdClock()
        let application = makePhase10Application(
            fixture: fixture,
            client: client,
            clock: clock,
            discoveryGate: discoveryGate
        )
        try await application.save(host)

        application.model.connect(to: host)
        try await waitUntilAsync { await discoveryGate.hasStarted() }
        try await waitUntil { application.model.isPanePickerPresented }
        try await waitUntilAsync { await clock.releaseThresholdWait() }

        application.model.cancelConnect()

        XCTAssertEqual(
            application.model.rowConnectionState(for: host),
            .idle
        )
        XCTAssertFalse(
            application.model.isPanePickerPresented,
            "Cancel during discovery must dismiss the loading picker"
        )
        XCTAssertNil(application.model.panePicker)
        // The SSH bootstrap was already live when discovery hung: the bounded
        // close must retire it.
        try await waitUntilAsync { await closeRecorder.closeCount() == 1 }
        let shellSession = await application.coordinator.activeShellSession()
        XCTAssertNil(shellSession)

        // Releasing the hung discovery must not resurrect adopted state.
        await discoveryGate.release()
        try await settle()
        XCTAssertNil(application.model.activeConnection)
        XCTAssertEqual(application.model.connectionState, .idle)
        XCTAssertNil(application.model.errorMessage)
        let attemptsAfterDiscovery = await client.connectionAttempts()
        XCTAssertEqual(attemptsAfterDiscovery, 1)

        application.model.connect(to: host)
        try await waitUntil { application.model.activeConnection != nil }
        let attemptsAfterRetry = await client.connectionAttempts()
        XCTAssertEqual(attemptsAfterRetry, 2)
        await tearDownConnection(application)
    }

    /// Overlap regression: the retired attempt's discovery is still gated when
    /// the retry starts. Releasing the gate finishes both tasks, and the stale
    /// one must not touch the coordinator: no abort of the retry's attempt and
    /// no close of the retry's live session.
    func testRetryWithDiscoveryStillGatedSurvivesRetiredAttempt()
        async throws
    {  // pi-lens-ignore: function_body_length
        let fixture = try Phase3HerdrFixtures.single()
        let host = phase4Host()
        let discoveryGate = Phase2ConnectionGate()
        let closeRecorder = Phase10ChannelCloseRecorder()
        let client = Phase10GatedSSHClient(closeRecorder: closeRecorder)
        let clock = Phase10CancelThresholdClock()
        let application = makePhase10Application(
            fixture: fixture,
            client: client,
            clock: clock,
            discoveryGate: discoveryGate
        )
        try await application.save(host)

        // Attempt 1 already owns a live SSH session and hangs in discovery.
        application.model.connect(to: host)
        try await waitUntilAsync { await discoveryGate.hasStarted() }
        try await waitUntil { application.model.isPanePickerPresented }
        try await waitUntilAsync { await clock.releaseThresholdWait() }
        application.model.cancelConnect()
        try await waitUntil {
            application.model.rowConnectionState(for: host) == .idle
        }

        // Retry while the retired attempt's discovery is still gated.
        application.model.connect(to: host)
        try await waitUntil { application.model.isPanePickerPresented }
        XCTAssertEqual(
            application.model.rowConnectionState(for: host),
            .connecting
        )

        // Releasing the gate wakes the retired and the retry discovery. The
        // retry must stay connected and keep its session.
        await discoveryGate.release()
        try await waitUntil { application.model.activeConnection != nil }
        try await settle()
        XCTAssertNil(application.model.errorMessage)
        let coordinatorState = await application.coordinator.connectionState()
        XCTAssertEqual(
            coordinatorState,
            .connected,
            "The retired discovery must not abort the retry"
        )
        let shellSession = await application.coordinator.activeShellSession()
        XCTAssertNotNil(
            shellSession,
            "The retired discovery must not close the retry's session"
        )
        XCTAssertEqual(application.model.connectionState, .connected)
        let attempts = await client.connectionAttempts()
        XCTAssertEqual(attempts, 2)
        await tearDownConnection(application)
    }

    // MARK: - Existing session safety

    func testCancelDoesNotDisturbConnectedSession() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let host = phase4Host()
        let closeRecorder = Phase10ChannelCloseRecorder()
        let client = Phase10GatedSSHClient(closeRecorder: closeRecorder)
        let application = makePhase10Application(
            fixture: fixture,
            client: client,
            clock: Phase10CancelThresholdClock()
        )
        try await application.save(host)

        application.model.connect(to: host)
        try await waitUntil { application.model.activeConnection != nil }
        let session = try XCTUnwrap(application.model.activeConnection?.session)
        XCTAssertNil(application.model.connectingHostID)
        XCTAssertEqual(application.model.connectionState, .connected)

        // A stale cancel tap (or a cancel for another row) must not disturb
        // the established session.
        application.model.cancelConnect()

        XCTAssertTrue(application.model.activeConnection?.session === session)
        let coordinatorState = await application.coordinator.connectionState()
        XCTAssertEqual(coordinatorState, .connected)
        try await settle()
        let closeCountAfterStaleCancel = await closeRecorder.closeCount()
        XCTAssertEqual(closeCountAfterStaleCancel, 0)
        XCTAssertEqual(application.model.connectionState, .connected)
        await tearDownConnection(application)
    }

    // MARK: - View hierarchy

    func testHostRowShowsProgressThenCancelAndReturnsToIdle() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let host = phase4Host()
        let gate = Phase2ConnectionGate()
        let client = Phase10GatedSSHClient(firstConnectionGate: gate)
        let clock = Phase10CancelThresholdClock()
        let application = makePhase10Application(
            fixture: fixture,
            client: client,
            clock: clock
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
            harness.view(with: "host-connecting-\(host.id.uuidString)"))
        XCTAssertNil(harness.view(with: "host-cancel-\(host.id.uuidString)"))

        XCTAssertTrue(
            activate("host-connect-\(host.id.uuidString)", in: harness)
        )
        let progressShown = await harness.waitUntil {
            harness.view(with: "host-connecting-\(host.id.uuidString)") != nil
        }
        XCTAssertTrue(
            progressShown,
            "Tapping connect must immediately show the row's progress indicator"
        )
        XCTAssertNil(harness.view(with: "host-cancel-\(host.id.uuidString)"))

        let released = await clock.releaseThresholdWait()
        XCTAssertTrue(released)
        let cancelShown = await harness.waitUntil {
            harness.view(with: "host-cancel-\(host.id.uuidString)") != nil
        }
        XCTAssertTrue(
            cancelShown,
            "Exceeding the threshold must reveal the row's Cancel button"
        )

        XCTAssertTrue(
            activate("host-cancel-\(host.id.uuidString)", in: harness)
        )
        let returnedToIdle = await harness.waitUntil {
            harness.view(with: "host-connecting-\(host.id.uuidString)") == nil
                && harness.view(with: "host-cancel-\(host.id.uuidString)") == nil
        }
        XCTAssertTrue(
            returnedToIdle,
            "Cancel must remove the progress indicator and the Cancel button"
        )
        XCTAssertNil(harness.view(with: "ssh-connection-error"))

        await gate.release()
        try await settle()
        XCTAssertNil(harness.view(with: "ssh-connection-error"))
        XCTAssertNil(application.model.activeConnection)
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
        let disconnectedShown = await harness.waitUntil {
            harness.view(with: "host-disconnected-\(host.id.uuidString)") != nil
        }
        XCTAssertTrue(
            disconnectedShown,
            "A disconnected host must show its state on the row"
        )
        XCTAssertNotNil(
            harness.view(with: "host-retry-\(host.id.uuidString)"),
            "The disconnected row must keep a retry path"
        )
        XCTAssertNil(
            harness.view(with: "hosts-connection-banner"),
            "Disconnected must not bring the banner back"
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

    // MARK: - Helpers

    private func makePhase10Application(
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

    private func tearDownConnection(
        _ application: Phase4NavigationApplication
    ) async {
        application.model.disconnect()
        try? await waitUntil { !application.model.isTearingDown }
    }

    /// Gives MainActor continuations (including the stale-attempt paths) a
    /// chance to run before a terminal assertion.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(100))
    }

    private func waitUntil(
        timeoutSeconds: Double = 3,
        line: Int = #line,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(timeoutSeconds)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Timed out (line \(line)) waiting for condition")
    }

    private func waitUntilAsync(
        timeoutSeconds: Double = 3,
        line: Int = #line,
        _ condition: () async -> Bool
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
    private func activate(
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
