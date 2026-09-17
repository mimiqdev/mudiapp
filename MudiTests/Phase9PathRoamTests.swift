import Foundation
import HerdrKit
import XCTest
@testable import Mudi

/// Path-change policy: a Mosh data plane roams over UDP, so an NWPathMonitor
/// interface-set change must never tear it down and never start an SSH
/// control-plane rebuild. The SSH bootstrap is rebuilt lazily — when the
/// user opens the Picker, or when Leave needs a live bootstrap to TERM the
/// recorded mosh-server pid.
@MainActor
final class Phase9PathRoamTests: XCTestCase {
    /// Mosh attached + wifi↔cellular (Tailscale `other` staying on both
    /// sides, matching the 2026-09-16T05:04 device log): no SSH reconnect
    /// attempt, no transparent overlay, identical on-screen session.
    func testMoshAttachedPathChangeDoesNotRebuildSSHControlPlane() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let pane = try XCTUnwrap(phase4Panes(in: fixture).first)
        var host = phase4Host()
        host.preferredTransport = .mosh
        let hostFileURL = phase4HostFileURL()
        defer {
            try? FileManager.default.removeItem(
                at: hostFileURL.deletingLastPathComponent()
            )
        }
        let pathMonitor = Phase9NetworkPathMonitor()
        let moshTransport = TestRecordingMoshTransport()
        let client = Phase2SSHClient(
            presentedFingerprint: "SHA256:phase4-test-key"
        )
        let application = makePhase4NavigationApplication(
            hostFileURL: hostFileURL,
            fixture: fixture,
            client: client,
            moshTransport: moshTransport,
            networkPathMonitor: pathMonitor
        )
        try await application.save(host)
        application.model.connect(to: host)
        try await waitUntil("initial picker") {
            application.model.isPanePickerPresented
                && application.model.connectionState == .connected
        }
        application.model.selectPaneFromPicker(pane.id)
        try await waitUntil("pane attached") {
            if case let .attached(_, attachedPane) = application.model.herdrState {
                return attachedPane.id == pane.id
                    && !application.model.isPanePickerPresented
            }
            return false
        }
        let moshSession = try XCTUnwrap(application.model.activeConnection?.session)
        XCTAssertEqual(application.model.activeConnection?.transport, .mosh)
        let moshCallsBefore = await moshTransport.getCalls().count

        // wifi+other → cellular+other: Tailscale stays up, only the
        // underlying interface set flaps.
        pathMonitor.emit(wifiPlusOtherSnapshot())
        try await waitUntil("wifi+other baseline") {
            application.model.networkPathRecovery.lastPath == wifiPlusOtherSnapshot()
        }
        pathMonitor.emit(cellularPlusOtherSnapshot())
        try await waitUntil("cellular+other observed") {
            application.model.networkPathRecovery.lastPath == cellularPlusOtherSnapshot()
        }
        try await Task.sleep(for: .milliseconds(500))

        let attempts = await client.connectionAttempts()
        XCTAssertEqual(
            attempts,
            1,
            "A path change while Mosh is mounted must not start an SSH connect"
        )
        XCTAssertFalse(
            application.model.isTransparentlyReconnecting,
            "Mosh roam must never show the transparent reconnect overlay"
        )
        XCTAssertNil(application.model.networkPathRecovery.transparentTask)
        XCTAssertIdentical(
            application.model.activeConnection?.session,
            moshSession,
            "The on-screen Mosh PTY session identity must be unchanged"
        )
        guard case let .attached(_, currentPane) = application.model.herdrState else {
            return XCTFail("The attached pane state must survive the roam")
        }
        XCTAssertEqual(currentPane.id, pane.id)
        XCTAssertEqual(application.model.activeTransport, .mosh)
        XCTAssertNil(application.model.errorMessage)
        let moshCallsAfter = await moshTransport.getCalls().count
        XCTAssertEqual(
            moshCallsAfter,
            moshCallsBefore,
            "A path change must not spawn a new mosh-server"
        )
        let moshDisconnects = await moshTransport.getDisconnectCount()
        XCTAssertEqual(
            moshDisconnects,
            0,
            "A path change must not tear the Mosh data plane down"
        )

        application.model.returnToHosts()
        try await waitUntil("teardown") { !application.model.isTearingDown }
    }

    /// Same binding for the ordinary (login-shell) Mosh terminal.
    func testMoshOrdinaryPathChangeDoesNotRebuildSSHControlPlane() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        var host = phase4Host()
        host.preferredTransport = .mosh
        let hostFileURL = phase4HostFileURL()
        defer {
            try? FileManager.default.removeItem(
                at: hostFileURL.deletingLastPathComponent()
            )
        }
        let pathMonitor = Phase9NetworkPathMonitor()
        let moshTransport = TestRecordingMoshTransport()
        let client = Phase2SSHClient(
            presentedFingerprint: "SHA256:phase4-test-key"
        )
        let application = makePhase4NavigationApplication(
            hostFileURL: hostFileURL,
            fixture: fixture,
            client: client,
            moshTransport: moshTransport,
            networkPathMonitor: pathMonitor
        )
        try await application.save(host)
        application.model.connect(to: host)
        try await waitUntil("initial picker") {
            application.model.isPanePickerPresented
                && application.model.connectionState == .connected
        }
        application.model.selectOrdinaryTerminalFromPicker()
        try await waitUntil("ordinary Mosh terminal") {
            application.model.herdrState == .ordinaryTerminal
                && !application.model.isPanePickerPresented
        }
        let moshSession = try XCTUnwrap(application.model.activeConnection?.session)

        pathMonitor.emit(wifiPlusOtherSnapshot())
        try await waitUntil("wifi+other baseline") {
            application.model.networkPathRecovery.lastPath == wifiPlusOtherSnapshot()
        }
        pathMonitor.emit(cellularPlusOtherSnapshot())
        try await waitUntil("cellular+other observed") {
            application.model.networkPathRecovery.lastPath == cellularPlusOtherSnapshot()
        }
        try await Task.sleep(for: .milliseconds(500))

        let attempts = await client.connectionAttempts()
        XCTAssertEqual(attempts, 1)
        XCTAssertFalse(application.model.isTransparentlyReconnecting)
        XCTAssertNil(application.model.networkPathRecovery.transparentTask)
        XCTAssertIdentical(
            application.model.activeConnection?.session,
            moshSession
        )
        XCTAssertEqual(application.model.herdrState, .ordinaryTerminal)
        XCTAssertNil(application.model.errorMessage)

        application.model.returnToHosts()
        try await waitUntil("teardown") { !application.model.isTearingDown }
    }

}

@MainActor
extension Phase9PathRoamTests {
    /// A path change observed while the scene is backgrounded must not
    /// rebuild SSH on activation when Mosh is mounted either.
    func testMoshPathChangeWhileBackgroundedDoesNotRebuildOnActivation() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        var host = phase4Host()
        host.preferredTransport = .mosh
        let hostFileURL = phase4HostFileURL()
        defer {
            try? FileManager.default.removeItem(
                at: hostFileURL.deletingLastPathComponent()
            )
        }
        let pathMonitor = Phase9NetworkPathMonitor()
        let moshTransport = TestRecordingMoshTransport()
        let client = Phase2SSHClient(
            presentedFingerprint: "SHA256:phase4-test-key"
        )
        let application = makePhase4NavigationApplication(
            hostFileURL: hostFileURL,
            fixture: fixture,
            client: client,
            moshTransport: moshTransport,
            networkPathMonitor: pathMonitor
        )
        try await application.save(host)
        application.model.connect(to: host)
        try await waitUntil("initial picker") {
            application.model.isPanePickerPresented
                && application.model.connectionState == .connected
        }
        application.model.selectOrdinaryTerminalFromPicker()
        try await waitUntil("ordinary Mosh terminal") {
            application.model.herdrState == .ordinaryTerminal
                && !application.model.isPanePickerPresented
        }
        let moshSession = try XCTUnwrap(application.model.activeConnection?.session)

        application.model.sceneWillResignActive()
        await application.model.sceneDidEnterBackground()
        XCTAssertTrue(application.model.isSceneBackgrounded)

        pathMonitor.emit(wifiPlusOtherSnapshot())
        try await waitUntil("wifi+other baseline") {
            application.model.networkPathRecovery.lastPath == wifiPlusOtherSnapshot()
        }
        pathMonitor.emit(cellularPlusOtherSnapshot())
        try await waitUntil("cellular+other observed") {
            application.model.networkPathRecovery.lastPath == cellularPlusOtherSnapshot()
        }

        await application.model.sceneDidBecomeActive()
        try await Task.sleep(for: .milliseconds(500))

        let attempts = await client.connectionAttempts()
        XCTAssertEqual(
            attempts,
            1,
            "Activation after a Mosh roam must not rebuild the SSH control plane"
        )
        XCTAssertFalse(application.model.isTransparentlyReconnecting)
        XCTAssertIdentical(
            application.model.activeConnection?.session,
            moshSession
        )
        XCTAssertNil(application.model.errorMessage)

        application.model.returnToHosts()
        try await waitUntil("teardown") { !application.model.isTearingDown }
    }

    /// When the SSH bootstrap died during the roam, opening the Picker is
    /// the moment the control plane is rebuilt; the terminal stays on the
    /// existing Mosh PTY and no overlay or navigation occurs.
    func testOpeningPickerAfterMoshPathChangeReconnectsSSH() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let pane = try XCTUnwrap(phase4Panes(in: fixture).first)
        var host = phase4Host()
        host.preferredTransport = .mosh
        let hostFileURL = phase4HostFileURL()
        defer {
            try? FileManager.default.removeItem(
                at: hostFileURL.deletingLastPathComponent()
            )
        }
        let pathMonitor = Phase9NetworkPathMonitor()
        let moshTransport = TestRecordingMoshTransport()
        let client = Phase2SSHClient(
            presentedFingerprint: "SHA256:phase4-test-key",
            // The path change retires the SSH bootstrap; the Picker-open
            // rebuild succeeds.
            outcomes: [false, false]
        )
        let application = makePhase4NavigationApplication(
            hostFileURL: hostFileURL,
            fixture: fixture,
            client: client,
            moshTransport: moshTransport,
            networkPathMonitor: pathMonitor
        )
        try await application.save(host)
        application.model.connect(to: host)
        try await waitUntil("initial picker") {
            application.model.isPanePickerPresented
                && application.model.connectionState == .connected
        }
        application.model.selectPaneFromPicker(pane.id)
        try await waitUntil("pane attached") {
            if case let .attached(_, attachedPane) = application.model.herdrState {
                return attachedPane.id == pane.id
                    && !application.model.isPanePickerPresented
            }
            return false
        }
        let moshSession = try XCTUnwrap(application.model.activeConnection?.session)

        pathMonitor.emit(wifiPlusOtherSnapshot())
        try await waitUntil("wifi+other baseline") {
            application.model.networkPathRecovery.lastPath == wifiPlusOtherSnapshot()
        }
        pathMonitor.emit(cellularPlusOtherSnapshot())
        try await waitUntil("SSH control retired") {
            application.model.networkPathRecovery.lastPath == cellularPlusOtherSnapshot()
                && application.model.networkPathRecovery.controlPlaneNeedsRebuild
        }
        try await waitUntil("retire close settles") {
            await application.coordinator.connectionState() != .connected
        }
        let attemptsAfterRoam = await client.connectionAttempts()
        XCTAssertEqual(
            attemptsAfterRoam,
            1,
            "Retiring the dead control plane must not reconnect SSH"
        )

        application.model.openPanePickerFromTerminal()
        try await waitUntil("picker open reconnects SSH") {
            await client.connectionAttempts() == 2
                && application.model.isPanePickerPresented
        }
        try await waitUntil("rebuild settled") {
            application.model.networkPathRecovery.transparentTask == nil
                && !application.model.isTransparentlyReconnecting
        }

        XCTAssertIdentical(
            application.model.activeConnection?.session,
            moshSession,
            "The terminal keeps the existing Mosh PTY across the rebuild"
        )
        XCTAssertEqual(application.model.activeTransport, .mosh)
        guard case let .attached(_, currentPane) = application.model.herdrState else {
            return XCTFail("The attached pane must survive the Picker-open rebuild")
        }
        XCTAssertEqual(currentPane.id, pane.id)
        XCTAssertNil(application.model.errorMessage)
        let snapshot = application.model.panePicker?.snapshot
        XCTAssertEqual(
            snapshot?.sessions.count,
            fixture.sessions.count,
            "The reopened Picker shows the fresh discovery snapshot"
        )

        application.model.dismissPanePicker()
        try await waitUntil("picker dismissed") {
            !application.model.isPanePickerPresented
        }
        application.model.returnToHosts()
        try await waitUntil("teardown") { !application.model.isTearingDown }
    }

    /// Leave after a roam rebuilds just enough SSH bootstrap to TERM the
    /// captured mosh-server pid, then finishes the return to Hosts.
    func testLeaveAfterMoshPathChangeTermsCapturedPidOnRebuiltBootstrap() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let pane = try XCTUnwrap(phase4Panes(in: fixture).first)
        var host = phase4Host()
        host.preferredTransport = .mosh
        let hostFileURL = phase4HostFileURL()
        defer {
            try? FileManager.default.removeItem(
                at: hostFileURL.deletingLastPathComponent()
            )
        }
        let pathMonitor = Phase9NetworkPathMonitor()
        let moshTransport = TestRecordingMoshTransport()
        let client = Phase2SSHClient(
            presentedFingerprint: "SHA256:phase4-test-key",
            outcomes: [false, false]
        )
        let application = makePhase4NavigationApplication(
            hostFileURL: hostFileURL,
            fixture: fixture,
            client: client,
            moshTransport: moshTransport,
            networkPathMonitor: pathMonitor
        )
        try await application.save(host)
        application.model.connect(to: host)
        try await waitUntil("initial picker") {
            application.model.isPanePickerPresented
                && application.model.connectionState == .connected
        }
        application.model.selectPaneFromPicker(pane.id)
        try await waitUntil("pane attached") {
            if case let .attached(_, attachedPane) = application.model.herdrState {
                return attachedPane.id == pane.id
                    && !application.model.isPanePickerPresented
            }
            return false
        }

        pathMonitor.emit(wifiPlusOtherSnapshot())
        try await waitUntil("wifi+other baseline") {
            application.model.networkPathRecovery.lastPath == wifiPlusOtherSnapshot()
        }
        pathMonitor.emit(cellularPlusOtherSnapshot())
        try await waitUntil("SSH control retired") {
            application.model.networkPathRecovery.controlPlaneNeedsRebuild
        }
        try await waitUntil("retire close settles") {
            await application.coordinator.connectionState() != .connected
        }

        application.model.returnToHosts()
        try await waitUntil("leave rebuilds SSH") {
            await client.connectionAttempts() == 2
        }
        try await waitUntil("teardown finished") {
            !application.model.isTearingDown
        }

        XCTAssertNil(application.model.activeConnection)
        XCTAssertNil(application.model.herdrState)
        let moshDisconnects = await moshTransport.getDisconnectCount()
        XCTAssertEqual(
            moshDisconnects,
            1,
            "Leave still stops the local Mosh client after the roam"
        )
    }

    /// A Leave fired while a Picker-open rebuild is still in flight must
    /// join that rebuild and still rebuild the bootstrap to TERM the
    /// captured mosh-server pid — it must not skip the TERM just because
    /// the rebuild was mid-handshake when navigation cancelled it.
    func testLeaveDuringInFlightPickerRebuildStillTermsCapturedPid() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let pane = try XCTUnwrap(phase4Panes(in: fixture).first)
        var host = phase4Host()
        host.preferredTransport = .mosh
        let hostFileURL = phase4HostFileURL()
        defer {
            try? FileManager.default.removeItem(
                at: hostFileURL.deletingLastPathComponent()
            )
        }
        let pathMonitor = Phase9NetworkPathMonitor()
        let moshTransport = TestRecordingMoshTransport()
        // Gate the rebuild connect (attempt >=2) so the Picker-open rebuild
        // is parked mid-handshake when Leave fires.
        let reconnectGate = Phase2ConnectionGate()
        let client = Phase2SSHClient(
            presentedFingerprint: "SHA256:phase4-test-key",
            reconnectGate: reconnectGate
        )
        let application = makePhase4NavigationApplication(
            hostFileURL: hostFileURL,
            fixture: fixture,
            client: client,
            moshTransport: moshTransport,
            networkPathMonitor: pathMonitor
        )
        try await application.save(host)
        application.model.connect(to: host)
        try await waitUntil("initial picker") {
            application.model.isPanePickerPresented
                && application.model.connectionState == .connected
        }
        application.model.selectPaneFromPicker(pane.id)
        try await waitUntil("pane attached") {
            if case let .attached(_, attachedPane) = application.model.herdrState {
                return attachedPane.id == pane.id
                    && !application.model.isPanePickerPresented
            }
            return false
        }

        pathMonitor.emit(wifiPlusOtherSnapshot())
        try await waitUntil("wifi+other baseline") {
            application.model.networkPathRecovery.lastPath == wifiPlusOtherSnapshot()
        }
        pathMonitor.emit(cellularPlusOtherSnapshot())
        try await waitUntil("roam retired ssh control") {
            application.model.networkPathRecovery.controlPlaneNeedsRebuild
        }

        // Open the picker: the deferred rebuild launches and parks on the
        // gated SSH connect.
        application.model.openPanePickerFromTerminal()
        await reconnectGate.waitUntilStarted()
        XCTAssertTrue(
            application.model.networkPathRecovery.controlPlaneRebuild == .inProgress
        )

        // Leave while the rebuild is still parked. Navigation cancels the
        // inner reconnect, but Leave must still rebuild the bootstrap and
        // TERM the captured mosh-server pid.
        await reconnectGate.release()
        application.model.returnToHosts()
        try await waitUntil("teardown finished") {
            !application.model.isTearingDown
        }

        let attempts = await client.connectionAttempts()
        XCTAssertGreaterThanOrEqual(
            attempts,
            2,
            "Leave must rebuild the SSH bootstrap to TERM the captured pid"
        )
        let moshDisconnects = await moshTransport.getDisconnectCount()
        XCTAssertEqual(
            moshDisconnects,
            1,
            "Leave still stops the local Mosh client"
        )
    }

    /// A failed Picker-open rebuild must restore the rebuild-needed state so
    /// the next Picker open retries instead of treating the dead control
    /// plane as live. Second open rebuilds SSH and presents the picker.
    func testFailedPickerOpenRebuildIsRetriedOnNextOpen() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let pane = try XCTUnwrap(phase4Panes(in: fixture).first)
        var host = phase4Host()
        host.preferredTransport = .mosh
        let hostFileURL = phase4HostFileURL()
        defer {
            try? FileManager.default.removeItem(
                at: hostFileURL.deletingLastPathComponent()
            )
        }
        let pathMonitor = Phase9NetworkPathMonitor()
        let moshTransport = TestRecordingMoshTransport()
        let client = Phase2SSHClient(
            presentedFingerprint: "SHA256:phase4-test-key",
            // connect ok -> first picker-open rebuild fails -> retry succeeds
            outcomes: [false, true, false]
        )
        let application = makePhase4NavigationApplication(
            hostFileURL: hostFileURL,
            fixture: fixture,
            client: client,
            moshTransport: moshTransport,
            networkPathMonitor: pathMonitor
        )
        try await application.save(host)
        application.model.connect(to: host)
        try await waitUntil("initial picker") {
            application.model.isPanePickerPresented
                && application.model.connectionState == .connected
        }
        application.model.selectPaneFromPicker(pane.id)
        try await waitUntil("pane attached") {
            if case let .attached(_, attachedPane) = application.model.herdrState {
                return attachedPane.id == pane.id
                    && !application.model.isPanePickerPresented
            }
            return false
        }
        let moshSession = try XCTUnwrap(application.model.activeConnection?.session)

        pathMonitor.emit(wifiPlusOtherSnapshot())
        try await waitUntil("wifi+other baseline") {
            application.model.networkPathRecovery.lastPath == wifiPlusOtherSnapshot()
        }
        pathMonitor.emit(cellularPlusOtherSnapshot())
        try await waitUntil("roam retired ssh control") {
            application.model.networkPathRecovery.controlPlaneNeedsRebuild
        }

        // First Picker open: rebuild attempt fails, flag must stay needed.
        application.model.openPanePickerFromTerminal()
        try await waitUntil("first rebuild attempt") {
            await client.connectionAttempts() == 2
        }
        try await waitUntil("first rebuild settled") {
            application.model.networkPathRecovery.transparentTask == nil
        }
        XCTAssertTrue(
            application.model.networkPathRecovery.controlPlaneNeedsRebuild,
            "A failed rebuild must keep the rebuild-needed state for retry"
        )
        XCTAssertFalse(
            application.model.isPanePickerPresented,
            "The picker must not present against a dead control plane"
        )
        XCTAssertIdentical(
            application.model.activeConnection?.session,
            moshSession,
            "The Mosh terminal stays mounted after the failed rebuild"
        )

        // Second Picker open retries the rebuild and now succeeds.
        application.model.openPanePickerFromTerminal()
        try await waitUntil("retry rebuilds SSH") {
            await client.connectionAttempts() == 3
                && application.model.isPanePickerPresented
        }
        try await waitUntil("retry settled") {
            application.model.networkPathRecovery.transparentTask == nil
        }
        XCTAssertFalse(application.model.networkPathRecovery.controlPlaneNeedsRebuild)
        XCTAssertIdentical(
            application.model.activeConnection?.session,
            moshSession
        )
        XCTAssertNil(application.model.errorMessage)

        application.model.dismissPanePicker()
        try await waitUntil("picker dismissed") {
            !application.model.isPanePickerPresented
        }
        application.model.returnToHosts()
        try await waitUntil("teardown") { !application.model.isTearingDown }
    }

    /// A flap during a rebuild defers its bootstrap retire to the end of the
    /// rebuild. The rebuild must keep ownership through that close, so a
    /// Picker open that lands mid-close joins the rebuild task and does not
    /// start a competing SSH handshake that the close could then abort.
    func testPickerOpenDuringPostRebuildCloseJoinsRebuildTask() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        var host = phase4Host()
        host.preferredTransport = .mosh
        let hostFileURL = phase4HostFileURL()
        defer {
            try? FileManager.default.removeItem(
                at: hostFileURL.deletingLastPathComponent()
            )
        }
        let pathMonitor = Phase9NetworkPathMonitor()
        let moshTransport = TestRecordingMoshTransport()
        // Gate the rebuilt bootstrap's close so the post-rebuild retire is
        // held open while a second Picker open arrives.
        let closeGate = Phase2ConnectionGate()
        let client = Phase2SSHClient(
            presentedFingerprint: "SHA256:phase4-test-key",
            outcomes: [false, false],
            closeGate: closeGate,
            closeGateFromAttempt: 2
        )
        let application = makePhase4NavigationApplication(
            hostFileURL: hostFileURL,
            fixture: fixture,
            client: client,
            moshTransport: moshTransport,
            networkPathMonitor: pathMonitor
        )
        try await application.save(host)
        application.model.connect(to: host)
        try await waitUntil("initial picker") {
            application.model.isPanePickerPresented
                && application.model.connectionState == .connected
        }
        application.model.selectOrdinaryTerminalFromPicker()
        try await waitUntil("ordinary Mosh terminal") {
            application.model.herdrState == .ordinaryTerminal
                && !application.model.isPanePickerPresented
        }
        let moshSession = try XCTUnwrap(application.model.activeConnection?.session)

        pathMonitor.emit(wifiPlusOtherSnapshot())
        try await waitUntil("wifi+other baseline") {
            application.model.networkPathRecovery.lastPath == wifiPlusOtherSnapshot()
        }
        pathMonitor.emit(cellularPlusOtherSnapshot())
        try await waitUntil("roam retired ssh control") {
            application.model.networkPathRecovery.controlPlaneNeedsRebuild
        }
        try await waitUntil("retire settled") {
            await application.coordinator.connectionState() != .connected
        }

        // Open the picker to start the rebuild (attempt 2).
        application.model.openPanePickerFromTerminal()
        try await waitUntil("rebuild connect started") {
            await client.connectionAttempts() == 2
        }

        // A second flap arrives while the rebuild owns the handshake: it
        // must defer the retire, not disconnect the bootstrap concurrently.
        pathMonitor.emit(wifiPlusOtherSnapshot())
        try await waitUntil("post-rebuild close held") {
            await closeGate.hasStarted()
        }

        // The post-rebuild close is now held open on the gated channel. A
        // Picker open during it must join the still-owned rebuild task, not
        // launch a third SSH connect.
        application.model.openPanePickerFromTerminal()
        try await Task.sleep(for: .milliseconds(200))
        let attemptsDuringClose = await client.connectionAttempts()
        XCTAssertEqual(
            attemptsDuringClose,
            2,
            "A Picker open during the post-rebuild close must not start a competing handshake"
        )
        XCTAssertIdentical(
            application.model.activeConnection?.session,
            moshSession,
            "The Mosh terminal stays mounted through the deferred retire"
        )

        await closeGate.release()
        try await waitUntil("close released") {
            application.model.networkPathRecovery.controlPlaneRebuild == .needed
                || application.model.networkPathRecovery.controlPlaneRebuild == .idle
        }

        application.model.returnToHosts()
        try await waitUntil("teardown") { !application.model.isTearingDown }
    }

    /// A Leave fired while the post-flap bootstrap close is held open must
    /// still finalize the cancelled rebuild and run a fresh bootstrap
    /// reconnect so the captured mosh-server pid is TERMed on a live
    /// replacement channel — not skipped because the cancelled task left
    /// the state stuck at .inProgress.
    func testLeaveDuringPostFlapCloseStillTermsOnRebuiltBootstrap() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let pane = try XCTUnwrap(phase4Panes(in: fixture).first)
        var host = phase4Host()
        host.preferredTransport = .mosh
        let hostFileURL = phase4HostFileURL()
        defer {
            try? FileManager.default.removeItem(
                at: hostFileURL.deletingLastPathComponent()
            )
        }
        let pathMonitor = Phase9NetworkPathMonitor()
        let moshTransport = TestRecordingMoshTransport()
        // Gate the rebuilt bootstrap's close so the post-rebuild retire is
        // held open when Leave fires.
        let closeGate = Phase2ConnectionGate()
        let client = Phase2SSHClient(
            presentedFingerprint: "SHA256:phase4-test-key",
            outcomes: [false, false],
            closeGate: closeGate,
            closeGateFromAttempt: 2
        )
        let application = makePhase4NavigationApplication(
            hostFileURL: hostFileURL,
            fixture: fixture,
            client: client,
            moshTransport: moshTransport,
            networkPathMonitor: pathMonitor
        )
        try await application.save(host)
        application.model.connect(to: host)
        try await waitUntil("initial picker") {
            application.model.isPanePickerPresented
                && application.model.connectionState == .connected
        }
        application.model.selectPaneFromPicker(pane.id)
        try await waitUntil("pane attached") {
            if case let .attached(_, attachedPane) = application.model.herdrState {
                return attachedPane.id == pane.id
                    && !application.model.isPanePickerPresented
            }
            return false
        }

        pathMonitor.emit(wifiPlusOtherSnapshot())
        try await waitUntil("wifi+other baseline") {
            application.model.networkPathRecovery.lastPath == wifiPlusOtherSnapshot()
        }
        pathMonitor.emit(cellularPlusOtherSnapshot())
        try await waitUntil("roam retired ssh control") {
            application.model.networkPathRecovery.controlPlaneNeedsRebuild
        }

        // Open the picker to start the rebuild (attempt 2), then flap again
        // mid-handshake so the rebuild defers a post-rebuild retire.
        application.model.openPanePickerFromTerminal()
        try await waitUntil("rebuild connect started") {
            await client.connectionAttempts() == 2
        }
        pathMonitor.emit(wifiPlusOtherSnapshot())
        try await waitUntil("post-rebuild close held") {
            await closeGate.hasStarted()
        }

        // Leave while the rebuilt bootstrap's close is still held. The
        // cancelled rebuild must finalize (restore .needed) and Leave must
        // run a fresh bootstrap reconnect to TERM the captured pid.
        application.model.returnToHosts()
        await closeGate.release()
        try await waitUntil("leave rebuilds SSH") {
            await client.connectionAttempts() >= 3
        }
        try await waitUntil("teardown finished") {
            !application.model.isTearingDown
        }

        XCTAssertNil(application.model.activeConnection)
        XCTAssertNil(application.model.herdrState)
        let moshDisconnects = await moshTransport.getDisconnectCount()
        XCTAssertEqual(
            moshDisconnects,
            1,
            "Leave still stops the local Mosh client"
        )
    }
}

private extension Phase9PathRoamTests {
    func wifiPlusOtherSnapshot() -> NetworkPathSnapshot {
        NetworkPathSnapshot(
            status: .satisfied,
            interfaces: [.wifi, .other],
            isExpensive: false,
            isConstrained: false
        )
    }

    func cellularPlusOtherSnapshot() -> NetworkPathSnapshot {
        NetworkPathSnapshot(
            status: .satisfied,
            interfaces: [.cellular, .other],
            isExpensive: true,
            isConstrained: false
        )
    }

    func cellularOnlySnapshot() -> NetworkPathSnapshot {
        NetworkPathSnapshot(
            status: .satisfied,
            interfaces: [.cellular],
            isExpensive: true,
            isConstrained: false
        )
    }

    func waitUntil(
        _ description: String = "",
        timeoutSeconds: Double = 2,
        _ condition: @MainActor () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        struct ConditionTimeout: Error, CustomStringConvertible {
            let message: String
            var description: String { message }
        }
        throw ConditionTimeout(message: "ConditionTimeout waiting for \(description)")
    }
}
