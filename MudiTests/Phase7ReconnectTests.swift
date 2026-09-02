import Foundation
import HerdrKit
import XCTest
@testable import Mudi

/// Transparent control-plane reconnection (phase 7): a dead SSH base
/// session detected on foreground resume triggers ONE reconnect attempt.
/// The terminal page stays mounted during the attempt (attached herdrState,
/// non-nil activeConnection, no Picker presentation); on success the fresh
/// context is swapped in atomically and the remembered pane retaken; on
/// failure the localized message + Host list.
@MainActor
final class Phase7ReconnectTests: XCTestCase {  // pi-lens-ignore: type_body_length
    func testTerminalStaysMountedThroughTransparentReconnect() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let pane = try XCTUnwrap(phase4Panes(in: fixture).first)
        let application = makePhase4NavigationApplication(fixture: fixture)
        let host = phase4Host()
        try await application.save(host)

        application.model.connect(to: host)
        try await waitUntil { application.model.activeConnection != nil }
        application.model.selectPane(pane.id)
        try await waitUntil {
            if case .attached = application.model.herdrState { return true }
            return false
        }

        // The transparent reconnect does NOT call beginConnection, so the
        // terminal context (attached herdrState + activeConnection) stays
        // mounted throughout: the model never reports Hosts mid-attempt.
        await application.transport.simulateBaseSessionDeath()
        await application.model.transparentControlPlaneReconnect(
            restoring: .rememberedPane
        )

        // The reconnect completed with the terminal still attached and the
        // Picker never presented by the reconnect itself.
        XCTAssertEqual(application.model.transparentReconnectAttemptsUsed, 1)
        XCTAssertFalse(application.model.isTransparentlyReconnecting)
        XCTAssertNotNil(application.model.activeConnection)
        guard case .attached(_, let retakenPane) = application.model.herdrState
        else {
            return XCTFail("The terminal must stay mounted through the reconnect")
        }
        XCTAssertEqual(retakenPane.id, pane.id)
        XCTAssertFalse(
            application.model.isPanePickerPresented,
            "The reconnect itself must not present the Picker"
        )
        XCTAssertNil(application.model.errorMessage)
    }

    func testTerminalContextIsUntouchedMidReconnect() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let pane = try XCTUnwrap(phase4Panes(in: fixture).first)
        let gate = Phase2ConnectionGate()
        let client = Phase2SSHClient(
            presentedFingerprint: "SHA256:phase4-test-key",
            reconnectGate: gate
        )
        let application = makePhase4NavigationApplication(
            fixture: fixture,
            client: client
        )
        let host = phase4Host()
        try await application.save(host)

        application.model.connect(to: host)
        try await waitUntil { application.model.activeConnection != nil }
        application.model.selectPane(pane.id)
        try await waitUntil {
            if case .attached = application.model.herdrState { return true }
            return false
        }

        await application.transport.simulateBaseSessionDeath()
        let reconnectTask = Task {
            await application.model.transparentControlPlaneReconnect(
                restoring: .rememberedPane
            )
        }

        // The reconnect is parked inside the fresh SSH bootstrap. The
        // terminal context must be fully intact mid-attempt: no Host
        // fallback (activeConnection/herdrState untouched) and no Picker.
        await gate.waitUntilStarted()
        XCTAssertTrue(application.model.isTransparentlyReconnecting)
        XCTAssertNotNil(
            application.model.activeConnection,
            "activeConnection must survive the attempt (no Host flash)"
        )
        guard case .attached = application.model.herdrState else {
            return XCTFail("herdrState must stay attached mid-attempt")
        }
        XCTAssertFalse(
            application.model.isPanePickerPresented,
            "The Picker must not cover the terminal mid-attempt"
        )

        await gate.release()
        await reconnectTask.value

        guard case .attached(_, let retakenPane) = application.model.herdrState
        else {
            return XCTFail("The remembered pane must be retaken")
        }
        XCTAssertEqual(retakenPane.id, pane.id)
        XCTAssertFalse(application.model.isPanePickerPresented)
        XCTAssertNil(application.model.errorMessage)
    }

    func testTransparentReconnectRetakesRememberedPane() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let pane = try XCTUnwrap(phase4Panes(in: fixture).first)
        let application = makePhase4NavigationApplication(fixture: fixture)
        let host = phase4Host()
        try await application.save(host)

        application.model.connect(to: host)
        try await waitUntil { application.model.activeConnection != nil }
        application.model.selectPane(pane.id)
        try await waitUntil {
            if case .attached = application.model.herdrState { return true }
            return false
        }
        let oldSession = try XCTUnwrap(
            application.model.activeConnection?.session
        )

        await application.transport.simulateBaseSessionDeath()
        await application.model.transparentControlPlaneReconnect(
            restoring: .rememberedPane
        )

        XCTAssertEqual(application.model.transparentReconnectAttemptsUsed, 1)
        XCTAssertNotNil(application.model.activeConnection)
        XCTAssertNotIdentical(
            application.model.activeConnection?.session,
            oldSession,
            "The reconnect must establish a fresh session"
        )
        guard case .attached(_, let retakenPane) = application.model.herdrState
        else {
            return XCTFail("The remembered pane must be retaken")
        }
        XCTAssertEqual(retakenPane.id, pane.id)
        XCTAssertNil(application.model.errorMessage)
    }

    func testReconnectFailureProducesLocalizedMessagAndHosts() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let application = makePhase4NavigationApplication(
            fixture: fixture,
            client: Phase2SSHClient(
                presentedFingerprint: "SHA256:phase4-test-key",
                outcomes: [false, true]
            )
        )
        let host = phase4Host()
        try await application.save(host)

        application.model.connect(to: host)
        try await waitUntil { application.model.activeConnection != nil }

        await application.transport.simulateBaseSessionDeath()
        await application.model.transparentControlPlaneReconnect(
            restoring: .rememberedPane
        )

        XCTAssertNil(
            application.model.activeConnection,
            "A failed reconnect must fall back to the Host list"
        )
        XCTAssertEqual(
            application.model.errorMessage,
            RootViewModel.transparentReconnectFailureMessage,
            "The failure message must be the localized human message"
        )
        XCTAssertFalse(
            application.model.errorMessage?
                .localizedCaseInsensitiveContains("NIOSSH") ?? true,
            "Raw NIOSSH text must never surface"
        )
    }

    func testReconnectIsOneShotPerInterruption() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let application = makePhase4NavigationApplication(fixture: fixture)
        let host = phase4Host()
        try await application.save(host)

        application.model.connect(to: host)
        try await waitUntil { application.model.activeConnection != nil }

        await application.transport.simulateBaseSessionDeath()
        await application.model.transparentControlPlaneReconnect(
            restoring: .ordinaryTerminal
        )
        XCTAssertEqual(application.model.transparentReconnectAttemptsUsed, 1)

        let sessionBefore = application.model.activeConnection?.session
        let attemptsBefore = application.model.transparentReconnectAttemptsUsed
        await application.transport.simulateBaseSessionDeath()
        await application.model.transparentControlPlaneReconnect(
            restoring: .ordinaryTerminal
        )
        XCTAssertEqual(
            application.model.transparentReconnectAttemptsUsed,
            attemptsBefore,
            "Only one attempt per interruption"
        )
        XCTAssertIdentical(
            application.model.activeConnection?.session,
            sessionBefore,
            "A blocked attempt must not touch the connection"
        )

        application.model.noteTransparentReconnectBudgetReset()
        XCTAssertEqual(application.model.transparentReconnectAttemptsUsed, 0)
    }

    func testOrdinaryTerminalDeathTriggersTransparentReconnect() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let application = makePhase4NavigationApplication(fixture: fixture)
        let host = phase4Host()
        try await application.save(host)

        application.model.connect(to: host)
        try await waitUntil { application.model.activeConnection != nil }
        application.model.selectOrdinaryTerminalFromPicker()
        try await waitUntil { application.model.herdrState == .ordinaryTerminal }
        let oldSession = try XCTUnwrap(
            application.model.activeConnection?.session
        )

        await application.transport.simulateBaseSessionDeath()
        await application.model.handleTerminalSessionClosed(
            for: ObjectIdentifier(oldSession)
        )
        try await waitUntil {
            application.model.activeConnection != nil
                && application.model.herdrState == .ordinaryTerminal
        }
        XCTAssertNotIdentical(
            application.model.activeConnection?.session,
            oldSession,
            "The reconnect must establish a fresh session"
        )
        XCTAssertNil(application.model.errorMessage)
    }

    // MARK: interruption recovery (review: reconnect-inactive-abort)

    func testOrdinaryTerminalCloseDuringInterruptionRecoversOnActivation()
        async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let application = makePhase4NavigationApplication(fixture: fixture)
        let host = phase4Host()
        try await application.save(host)

        application.model.connect(to: host)
        try await waitUntil { application.model.activeConnection != nil }
        application.model.selectOrdinaryTerminalFromPicker()
        try await waitUntil { application.model.herdrState == .ordinaryTerminal }
        let session = try XCTUnwrap(
            application.model.activeConnection?.session
        )

        // Lock, then the session dies and its close surfaces while the
        // scene is inactive: recorded, nothing else moves.
        application.model.sceneWillResignActive()
        await application.model.sceneDidEnterBackground()
        await application.transport.simulateBaseSessionDeath()
        await application.model.handleTerminalSessionClosed(
            for: ObjectIdentifier(session)
        )
        XCTAssertNotNil(
            application.model.pendingTerminalCloseIdentity,
            "The interrupted close must be recorded for activation recovery"
        )
        XCTAssertIdentical(
            application.model.activeConnection?.session, session,
            "The close must not move the terminal while inactive"
        )
        XCTAssertNil(application.model.errorMessage)

        // Unlock: the one-shot recovery re-runs the bootstrap.
        await application.model.sceneDidBecomeActive()
        try await waitUntil {
            application.model.activeConnection?.session !== session
                && application.model.herdrState == .ordinaryTerminal
        }
        XCTAssertNil(application.model.errorMessage)
        XCTAssertNil(application.model.pendingTerminalCloseIdentity)
        let connectionState = await application.coordinator.connectionState()
        XCTAssertEqual(connectionState, .connected)
    }

    func testMidFlightReconnectAbortRecoversOnNextActivation() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let gate = Phase2ConnectionGate()
        let client = Phase2SSHClient(
            presentedFingerprint: "SHA256:phase4-test-key",
            reconnectGate: gate
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
        let session = try XCTUnwrap(
            application.model.activeConnection?.session
        )

        // The close fires while ACTIVE: the reconnect starts and parks
        // inside the gated SSH bootstrap.
        await application.transport.simulateBaseSessionDeath()
        let reconnectTask = Task {
            await application.model.handleTerminalSessionClosed(
                for: ObjectIdentifier(session)
            )
        }
        await gate.waitUntilStarted()

        // Re-lock mid-attempt, then let the attempt resume: it bails after
        // its disconnect, leaving the terminal mounted with a diverged
        // coordinator - and a recorded close for the next activation.
        application.model.sceneWillResignActive()
        await application.model.sceneDidEnterBackground()
        await gate.release()
        await reconnectTask.value
        XCTAssertIdentical(
            application.model.activeConnection?.session, session,
            "The aborted attempt must leave the terminal mounted"
        )
        XCTAssertNotNil(application.model.pendingTerminalCloseIdentity)
        XCTAssertFalse(application.model.isTransparentlyReconnecting)

        // Unlock: the recovery re-runs the one-shot reconnect.
        await application.model.sceneDidBecomeActive()
        try await waitUntil {
            application.model.activeConnection?.session !== session
                && application.model.herdrState == .ordinaryTerminal
        }
        XCTAssertNil(application.model.errorMessage)
        XCTAssertNil(application.model.pendingTerminalCloseIdentity)
    }

    func testAttachedInactiveCloseReconnectsExactlyOnce() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let pane = try XCTUnwrap(phase4Panes(in: fixture).first)
        let gate = Phase2ConnectionGate()
        let client = Phase2SSHClient(
            presentedFingerprint: "SHA256:phase4-test-key",
            reconnectGate: gate
        )
        let application = makePhase4NavigationApplication(
            fixture: fixture,
            client: client
        )
        let host = phase4Host()
        try await application.save(host)

        application.model.connect(to: host)
        try await waitUntil { application.model.activeConnection != nil }
        application.model.selectPane(pane.id)
        try await waitUntil {
            if case .attached = application.model.herdrState { return true }
            return false
        }
        let session = try XCTUnwrap(
            application.model.activeConnection?.session
        )

        // Lock; the control is suspended and the close surfaces inactive.
        application.model.sceneWillResignActive()
        await application.model.sceneDidEnterBackground()
        await application.transport.setMissingPaneIDs([pane.id])
        await application.transport.simulateBaseSessionDeath()
        await application.model.handleTerminalSessionClosed(
            for: ObjectIdentifier(session)
        )
        XCTAssertNotNil(application.model.pendingTerminalCloseIdentity)

        // Unlock: the resume fails (pane unavailable), the reconnect parks
        // at the gated bootstrap; heal the pane, then let the retake land.
        let activationTask = Task {
            await application.model.sceneDidBecomeActive()
        }
        await gate.waitUntilStarted()
        await application.transport.setMissingPaneIDs([])
        await gate.release()
        await activationTask.value

        try await waitUntil {
            if case .attached(_, let retaken) = application.model.herdrState {
                return retaken.id == pane.id
            }
            return false
        }
        XCTAssertFalse(application.model.isPanePickerPresented)
        XCTAssertNil(application.model.pendingTerminalCloseIdentity)
        let attempts = await client.connectionAttempts()
        XCTAssertEqual(
            attempts, 2,
            "Exactly one reconnect: the resume + recorded close must not double-fire"
        )
    }

    // MARK: snapshot cache (stale-while-revalidate)

    func testSuccessfulDiscoveryPopulatesSnapshotCache() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let application = makePhase4NavigationApplication(fixture: fixture)
        let host = phase4Host()
        try await application.save(host)

        application.model.connect(to: host)
        try await waitUntil { application.model.panePicker != nil }

        let cached = application.model.cachedPickerSnapshot(for: host)
        let fixturePaneIDs = Set(phase4Panes(in: fixture).map(\.id))
        let cachedPaneIDs = Set(
            cached.sessions.flatMap { $0.workspaces }
                .flatMap { $0.tabs }
                .flatMap { $0.panes }
                .map(\.id)
        )
        XCTAssertEqual(cachedPaneIDs, fixturePaneIDs)
    }

    func testControlPlaneOutageFallsBackToCachedSnapshot() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let application = makePhase4NavigationApplication(fixture: fixture)
        let host = phase4Host()
        try await application.save(host)

        application.model.connect(to: host)
        try await waitUntil { application.model.panePicker != nil }
        let cachedBefore = application.model.cachedPickerSnapshot(for: host)

        // Base session dead AND the picker control plane unavailable: the
        // reconnect presents the cached snapshot instead of a dead end.
        await application.transport.simulateBaseSessionDeath()
        await application.transport.failNextConnectAttempt()
        await application.model.transparentControlPlaneReconnect(
            restoring: .rememberedPane
        )

        XCTAssertTrue(application.model.isPanePickerPresented)
        XCTAssertEqual(
            application.model.panePicker?.snapshot,
            cachedBefore,
            "The picker must show the cached snapshot during the outage"
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
