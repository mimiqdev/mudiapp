import HerdrKit
import SwiftUI
import XCTest
@testable import Mudi

/// Phase 10, first slice: the Hosts-list connecting feedback and its cancel
/// affordance. These tests drive the production RootViewModel and RootView
/// with an injectable clock so the 5-second threshold is deterministic.
final class Phase10ConnectingFeedbackTests: Phase10TestCase {  // pi-lens-ignore: type_body_length
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
}
