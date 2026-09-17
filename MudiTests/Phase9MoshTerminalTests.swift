import Foundation
import HerdrKit
import XCTest
@testable import Mudi

@MainActor
final class Phase9MoshTerminalTests: XCTestCase {
    func testMoshHostAttachPaneUsesMoshDataSessionAndKeepsTransportMosh() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let oldPane = phase4Panes(in: fixture)[0]
        var host = phase4Host()
        host.preferredTransport = .mosh
        let hostFileURL = phase4HostFileURL()
        defer {
            try? FileManager.default.removeItem(
                at: hostFileURL.deletingLastPathComponent()
            )
        }
        let moshTransport = TestRecordingMoshTransport()
        let application = makePhase4NavigationApplication(
            hostFileURL: hostFileURL,
            fixture: fixture,
            moshTransport: moshTransport
        )

        try await application.save(host)
        application.model.connect(to: host)

        try await waitUntil {
            application.model.isPanePickerPresented
                && application.model.activeConnection != nil
                && application.model.connectionState == .connected
        }

        application.model.selectPaneFromPicker(oldPane.id)

        try await waitUntil {
            if case let .attached(_, attachedPane) = application.model.herdrState {
                return attachedPane.id == oldPane.id
                    && !application.model.isPanePickerPresented
            }
            return false
        }

        XCTAssertEqual(application.model.activeConnection?.transport, ActiveTransport.mosh)
        let activeSession = try XCTUnwrap(application.model.activeConnection?.session)

        XCTAssertFalse(activeSession === application.model.baseSession)

        let moshSessions = await moshTransport.getCreatedSessions()
        XCTAssertEqual(moshSessions.count, 2, "Expected 1 login shell Mosh session + 1 attached pane Mosh session")
        guard moshSessions.count >= 2 else { return }
        XCTAssertTrue(
            activeSession === moshSessions[1],
            "Attached TerminalScreen session must be the raw Mosh PTY session"
        )
        let supportsScrollback = await activeSession.supportsRemoteScrollback()
        XCTAssertFalse(
            supportsScrollback,
            "Mosh data sessions must not be wrapped in HerdrControlChannel"
        )

        let calls = await moshTransport.getCalls()
        XCTAssertEqual(calls.count, 2)
        guard calls.count >= 2 else { return }
        XCTAssertNil(calls[0].command, "Initial login shell Mosh session should have no command")
        let attachCommand = try XCTUnwrap(calls[1].command)
        let terminalID = try XCTUnwrap(oldPane.terminalID)
        XCTAssertTrue(terminalID.hasPrefix("term_"))
        let attachStart = try XCTUnwrap(
            attachCommand.range(of: "herdr terminal attach")?.upperBound
        )
        let takeoverStart = try XCTUnwrap(
            attachCommand.range(
                of: "--takeover",
                range: attachStart..<attachCommand.endIndex
            )?.lowerBound
        )
        XCTAssertNotNil(
            attachCommand.range(
                of: terminalID,
                range: attachStart..<takeoverStart
            ),
            "Mosh attach must place the terminal stream id before --takeover"
        )
        XCTAssertNil(
            attachCommand.range(
                of: oldPane.id,
                range: attachStart..<takeoverStart
            ),
            "Mosh attach must not pass the pane id as the terminal stream id"
        )
        XCTAssertFalse(attachCommand.contains("herdr terminal attach --takeover"))
        XCTAssertFalse(attachCommand.contains("terminal session control"))
        XCTAssertFalse(attachCommand.contains("--cols"))
        XCTAssertFalse(attachCommand.contains("--rows"))

        // Raw Mosh data plane: keystrokes go directly to the Mosh PTY.
        try await activeSession.send(Array("hi".utf8))
        let ptys = await moshTransport.getCreatedPTYs()
        guard ptys.count >= 2 else { return }
        let attachedPTY = ptys[1]
        let sentToMosh = await attachedPTY.getSentBytes()
        XCTAssertEqual(sentToMosh, [Array("hi".utf8)])

        // Raw Mosh data plane: PTY output reaches TerminalScreen unchanged.
        let outputStream = await activeSession.outputStream()
        await attachedPTY.yieldOutput(Array("ok".utf8))
        var iterator = outputStream.makeAsyncIterator()
        let receivedBytes = try await iterator.next()
        let receivedString = String(bytes: receivedBytes ?? [], encoding: .utf8)
        XCTAssertEqual(receivedString, "ok")
    }

    func testMoshAttachWithoutTerminalIDFailsBeforeStartingMosh() async throws {
        let moshTransport = TestRecordingMoshTransport()
        let transport = MoshHerdrTerminalTransport(
            session: SSHShellSession(connectedChannel: TestMoshPTY()),
            host: phase4Host(),
            credentialsProvider: { phase2Credentials() },
            moshTransport: moshTransport
        )
        let pane = Pane(
            id: "w55:p1",
            title: "Missing terminal stream",
            terminalID: nil
        )

        do {
            try await transport.attach(to: pane)
            XCTFail("A pane without a terminal_id must not attach")
        } catch {
            let transportError = try XCTUnwrap(
                error as? SSHHerdrTerminalTransportError
            )
            XCTAssertEqual(
                transportError.errorDescription,
                "The selected Herdr pane has no terminal stream ID."
            )
        }

        let calls = await moshTransport.getCalls()
        XCTAssertTrue(calls.isEmpty)
    }

    func testSelectingOrdinaryTerminalAfterMoshPaneAttachStartsFreshLoginShell() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let pane = phase4Panes(in: fixture)[0]
        var host = phase4Host()
        host.preferredTransport = .mosh
        let hostFileURL = phase4HostFileURL()
        defer {
            try? FileManager.default.removeItem(
                at: hostFileURL.deletingLastPathComponent()
            )
        }
        let moshTransport = TestRecordingMoshTransport()
        let application = makePhase4NavigationApplication(
            hostFileURL: hostFileURL,
            fixture: fixture,
            moshTransport: moshTransport
        )

        try await application.save(host)
        application.model.connect(to: host)
        try await waitUntil("initial Mosh picker") {
            application.model.isPanePickerPresented
                && application.model.connectionState == .connected
        }
        let initialLoginSession = try XCTUnwrap(
            application.model.baseTerminalSession
        )

        application.model.selectPaneFromPicker(pane.id)
        try await waitUntil("Mosh pane attached") {
            if case let .attached(_, attachedPane) = application.model.herdrState {
                return attachedPane.id == pane.id
                    && !application.model.isPanePickerPresented
            }
            return false
        }
        let paneSession = try XCTUnwrap(application.model.activeConnection?.session)
        XCTAssertFalse(paneSession === initialLoginSession)
        let ptysAfterAttach = await moshTransport.getCreatedPTYs()
        let initialPTYClosed = await ptysAfterAttach[0].getIsClosed()
        XCTAssertTrue(initialPTYClosed, "Pane attach replaces the login-shell Mosh session")

        application.model.openPanePickerFromTerminal()
        try await waitUntil("terminal picker presented") {
            application.model.isPanePickerPresented
        }
        application.model.selectOrdinaryTerminalFromPicker()
        try await waitUntil("fresh ordinary Mosh terminal") {
            application.model.herdrState == .ordinaryTerminal
                && !application.model.isPanePickerPresented
        }

        let ordinarySession = try XCTUnwrap(application.model.activeConnection?.session)
        XCTAssertTrue(ordinarySession === application.model.baseTerminalSession)
        XCTAssertFalse(ordinarySession === initialLoginSession)
        XCTAssertFalse(ordinarySession === application.model.baseSession)

        let calls = await moshTransport.getCalls()
        XCTAssertEqual(calls.count, 3, "Fresh ordinary terminal needs a new Mosh login shell")
        XCTAssertNil(calls.last?.command)
        let ptys = await moshTransport.getCreatedPTYs()
        guard ptys.count > 2 else {
            return XCTFail("Ordinary terminal must create a replacement Mosh session")
        }
        let ordinaryPTYClosed = await ptys[2].getIsClosed()
        XCTAssertFalse(ordinaryPTYClosed, "Ordinary terminal must use the replacement Mosh session")
    }

    func testMoshPathChangeAfterPaneThenOrdinaryPreservesLiveLoginSession() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let pane = phase4Panes(in: fixture)[0]
        var host = phase4Host()
        host.preferredTransport = .mosh
        let hostFileURL = phase4HostFileURL()
        defer {
            try? FileManager.default.removeItem(
                at: hostFileURL.deletingLastPathComponent()
            )
        }
        let client = Phase2SSHClient(
            presentedFingerprint: "SHA256:phase4-test-key"
        )
        let pathMonitor = Phase9NetworkPathMonitor()
        let moshTransport = TestRecordingMoshTransport()
        let application = makePhase4NavigationApplication(
            hostFileURL: hostFileURL,
            fixture: fixture,
            client: client,
            moshTransport: moshTransport,
            networkPathMonitor: pathMonitor
        )

        try await application.save(host)
        application.model.connect(to: host)
        try await waitUntil("initial Mosh picker") {
            application.model.isPanePickerPresented
                && application.model.connectionState == .connected
        }
        application.model.selectPaneFromPicker(pane.id)
        try await waitUntil("Mosh pane attached") {
            if case let .attached(_, attachedPane) = application.model.herdrState {
                return attachedPane.id == pane.id
                    && !application.model.isPanePickerPresented
            }
            return false
        }

        application.model.openPanePickerFromTerminal()
        try await waitUntil("terminal picker presented") {
            application.model.isPanePickerPresented
        }
        application.model.selectOrdinaryTerminalFromPicker()
        try await waitUntil("ordinary Mosh terminal") {
            application.model.herdrState == .ordinaryTerminal
                && !application.model.isPanePickerPresented
        }
        let ordinarySession = try XCTUnwrap(application.model.activeConnection?.session)

        let wifi = NetworkPathSnapshot(
            status: .satisfied,
            interfaces: [.wifi],
            isExpensive: false,
            isConstrained: false
        )
        pathMonitor.emit(wifi)
        try await waitUntil("wifi lastPath") {
            application.model.networkPathRecovery.lastPath == wifi
        }
        let cellular = NetworkPathSnapshot(
            status: .satisfied,
            interfaces: [.cellular],
            isExpensive: true,
            isConstrained: false
        )
        pathMonitor.emit(cellular)
        try await waitUntil("cellular lastPath") {
            application.model.networkPathRecovery.lastPath == cellular
        }
        // A path change must not rebuild the SSH control plane while Mosh
        // owns the terminal: no new connect, no overlay, session identity
        // unchanged.
        try await Task.sleep(for: .milliseconds(400))
        let attempts = await client.connectionAttempts()
        XCTAssertEqual(attempts, 1, "Mosh roam must not start an SSH rebuild")
        XCTAssertFalse(application.model.isTransparentlyReconnecting)
        XCTAssertNil(application.model.networkPathRecovery.transparentTask)

        let remountedSession = try XCTUnwrap(application.model.activeConnection?.session)
        XCTAssertTrue(remountedSession === ordinarySession)
        do {
            try await remountedSession.send(Array("ok".utf8))
        } catch {
            XCTFail("The preserved ordinary Mosh session must remain live: \(error)")
        }
        let ptys = await moshTransport.getCreatedPTYs()
        guard ptys.count > 2 else {
            return XCTFail("Attach-then-ordinary must create a login-shell Mosh session")
        }
        let ordinaryPTYClosed = await ptys[2].getIsClosed()
        XCTAssertFalse(ordinaryPTYClosed)
    }

    func testSwitchingPickerPanesDoesNotLeaveSSHSessionOnTerminalScreen() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let panes = phase4Panes(in: fixture)
        let pane1 = panes[0]
        let pane2 = panes[1]
        var host = phase4Host()
        host.preferredTransport = .mosh
        let hostFileURL = phase4HostFileURL()
        defer {
            try? FileManager.default.removeItem(
                at: hostFileURL.deletingLastPathComponent()
            )
        }
        let moshTransport = TestRecordingMoshTransport()
        let application = makePhase4NavigationApplication(
            hostFileURL: hostFileURL,
            fixture: fixture,
            moshTransport: moshTransport
        )

        try await application.save(host)
        application.model.connect(to: host)

        try await waitUntil {
            application.model.isPanePickerPresented
                && application.model.connectionState == .connected
        }

        application.model.selectPaneFromPicker(pane1.id)
        try await waitUntil {
            if case let .attached(_, attachedPane) = application.model.herdrState {
                return attachedPane.id == pane1.id && !application.model.isPanePickerPresented
            }
            return false
        }

        XCTAssertEqual(application.model.activeConnection?.transport, ActiveTransport.mosh)
        let session1 = try XCTUnwrap(application.model.activeConnection?.session)
        XCTAssertFalse(session1 === application.model.baseSession)

        application.model.openPanePickerFromTerminal()
        try await waitUntil { application.model.isPanePickerPresented }

        application.model.selectPaneFromPicker(pane2.id)
        try await waitUntil {
            if case let .attached(_, attachedPane) = application.model.herdrState {
                return attachedPane.id == pane2.id && !application.model.isPanePickerPresented
            }
            return false
        }

        XCTAssertEqual(application.model.activeConnection?.transport, ActiveTransport.mosh)
        let session2 = try XCTUnwrap(application.model.activeConnection?.session)
        XCTAssertFalse(session2 === application.model.baseSession)
        XCTAssertFalse(session2 === session1, "Switching panes must replace the Mosh data session")

        let moshSessions = await moshTransport.getCreatedSessions()
        XCTAssertEqual(moshSessions.count, 3, "1 login shell + 1 pane1 + 1 pane2")
    }

    func testMoshPathChangeWhileAttachedKeepsTerminalMountedWithNoOverlayAndPreservesSession()
        async throws
    {
        let fixture = try Phase3HerdrFixtures.single()
        let pane = phase4Panes(in: fixture)[0]
        var host = phase4Host()
        host.preferredTransport = .mosh
        let hostFileURL = phase4HostFileURL()
        defer {
            try? FileManager.default.removeItem(
                at: hostFileURL.deletingLastPathComponent()
            )
        }
        let client = Phase2SSHClient(
            presentedFingerprint: "SHA256:phase4-test-key"
        )
        let pathMonitor = Phase9NetworkPathMonitor()
        let moshTransport = TestRecordingMoshTransport()
        let application = makePhase4NavigationApplication(
            hostFileURL: hostFileURL,
            fixture: fixture,
            client: client,
            moshTransport: moshTransport,
            networkPathMonitor: pathMonitor
        )

        try await application.save(host)
        application.model.connect(to: host)

        try await waitUntil {
            application.model.isPanePickerPresented
                && application.model.connectionState == .connected
        }

        application.model.selectPaneFromPicker(pane.id)
        try await waitUntil {
            if case let .attached(_, attachedPane) = application.model.herdrState {
                return attachedPane.id == pane.id && !application.model.isPanePickerPresented
            }
            return false
        }

        let moshSession: SSHShellSession = try XCTUnwrap(application.model.activeConnection?.session)
        XCTAssertEqual(application.model.activeConnection?.transport, ActiveTransport.mosh)

        let satisfiedWiFi = NetworkPathSnapshot(
            status: .satisfied,
            interfaces: [.wifi],
            isExpensive: false,
            isConstrained: false
        )
        pathMonitor.emit(satisfiedWiFi)
        try await waitUntil {
            application.model.networkPathRecovery.lastPath == satisfiedWiFi
        }

        let satisfiedCellular = NetworkPathSnapshot(
            status: .satisfied,
            interfaces: [.cellular],
            isExpensive: true,
            isConstrained: false
        )
        pathMonitor.emit(satisfiedCellular)
        try await waitUntil {
            application.model.networkPathRecovery.lastPath == satisfiedCellular
        }

        // A path change roams Mosh over UDP: no SSH rebuild, no overlay,
        // identical on-screen session, attached pane preserved.
        try await Task.sleep(for: .milliseconds(400))
        let attempts = await client.connectionAttempts()
        XCTAssertEqual(
            attempts,
            1,
            "Mosh roam must not start an SSH control-plane rebuild"
        )
        XCTAssertFalse(
            application.model.isTransparentlyReconnecting,
            "Mosh data plane must not display reconnect overlay on path change"
        )
        XCTAssertNil(application.model.networkPathRecovery.transparentTask)
        XCTAssertTrue(
            application.model.activeConnection?.session === moshSession,
            "On-screen Mosh session must remain identical across path change"
        )
        guard case let .attached(_, currentPane) = application.model.herdrState else {
            return XCTFail("Terminal must remain attached during path change")
        }
        XCTAssertEqual(currentPane.id, pane.id)
        XCTAssertEqual(application.model.activeConnection?.transport, ActiveTransport.mosh)
        XCTAssertNil(application.model.errorMessage)
    }

    /// After a roam the SSH control plane is rebuilt lazily on Picker open.
    /// The rebuilt workflow must be hydrated with the still-live Mosh
    /// session so re-selecting the same pane is a no-op and selecting a
    /// different pane attaches over the new control plane.
    func testMoshPathChangePickerOpenRebuildHydratesTransportAndPreservesSessionOnLaterSelect()
        async throws
    {
        let fixture = try Phase3HerdrFixtures.single()
        let panes = phase4Panes(in: fixture)
        let pane1 = panes[0]
        let pane2 = panes[1]
        var host = phase4Host()
        host.preferredTransport = .mosh
        let hostFileURL = phase4HostFileURL()
        defer {
            try? FileManager.default.removeItem(
                at: hostFileURL.deletingLastPathComponent()
            )
        }
        let client = Phase2SSHClient(
            presentedFingerprint: "SHA256:phase4-test-key",
            outcomes: [false, false]
        )
        let pathMonitor = Phase9NetworkPathMonitor()
        let moshTransport = TestRecordingMoshTransport()
        let application = makePhase4NavigationApplication(
            hostFileURL: hostFileURL,
            fixture: fixture,
            client: client,
            moshTransport: moshTransport,
            networkPathMonitor: pathMonitor
        )

        try await application.save(host)
        application.model.connect(to: host)

        try await waitUntil("picker presented") {
            application.model.isPanePickerPresented
                && application.model.connectionState == .connected
        }

        application.model.selectPaneFromPicker(pane1.id)
        try await waitUntil("pane1 attached") {
            if case let .attached(_, attachedPane) = application.model.herdrState {
                return attachedPane.id == pane1.id && !application.model.isPanePickerPresented
            }
            return false
        }

        let moshSession1: SSHShellSession = try XCTUnwrap(application.model.activeConnection?.session)

        let satisfiedWiFi = NetworkPathSnapshot(
            status: .satisfied,
            interfaces: [.wifi],
            isExpensive: false,
            isConstrained: false
        )
        pathMonitor.emit(satisfiedWiFi)
        try await waitUntil("wifi lastPath") {
            application.model.networkPathRecovery.lastPath == satisfiedWiFi
        }

        let satisfiedCellular = NetworkPathSnapshot(
            status: .satisfied,
            interfaces: [.cellular],
            isExpensive: true,
            isConstrained: false
        )
        pathMonitor.emit(satisfiedCellular)
        try await waitUntil("roam retired ssh control") {
            application.model.networkPathRecovery.controlPlaneNeedsRebuild
        }

        // The roam itself must not reconnect SSH; the rebuild waits for the
        // next Picker open.
        let attemptsAfterRoam = await client.connectionAttempts()
        XCTAssertEqual(attemptsAfterRoam, 1)
        XCTAssertTrue(application.model.activeConnection?.session === moshSession1)

        application.model.openPanePickerFromTerminal()
        try await waitUntil("picker open rebuilds SSH") {
            await client.connectionAttempts() == 2
                && application.model.isPanePickerPresented
        }
        try await waitUntil("rebuild settled") {
            application.model.networkPathRecovery.transparentTask == nil
                && !application.model.isTransparentlyReconnecting
        }

        XCTAssertTrue(application.model.activeConnection?.session === moshSession1)

        guard let workflow = application.model.workflow else {
            return XCTFail("Workflow must be present")
        }
        let workflowState = await workflow.currentState()
        guard case let .attached(_, attachedPane) = workflowState else {
            return XCTFail("Workflow must be in attached state after rebuild")
        }
        XCTAssertEqual(attachedPane.id, pane1.id)
        let workflowSession = await workflow.terminalSession()
        XCTAssertTrue(workflowSession === moshSession1)

        let callCountBefore = await moshTransport.getCalls().count
        application.model.selectPaneFromPicker(pane1.id)
        try await waitUntil("dismiss picker on re-select") { !application.model.isPanePickerPresented }

        let callCountAfter = await moshTransport.getCalls().count
        XCTAssertEqual(callCountAfter, callCountBefore, "Re-selecting pane must not start new Mosh session")
        XCTAssertTrue(application.model.activeConnection?.session === moshSession1)

        application.model.openPanePickerFromTerminal()
        try await waitUntil("openPanePickerFromTerminal 2") { application.model.isPanePickerPresented }

        application.model.selectPaneFromPicker(pane2.id)
        try await waitUntil("pane2 attached") {
            if case let .attached(_, attachedPane) = application.model.herdrState {
                return attachedPane.id == pane2.id && !application.model.isPanePickerPresented
            }
            return false
        }
        XCTAssertFalse(application.model.activeConnection?.session === moshSession1)
        XCTAssertEqual(application.model.activeConnection?.transport, ActiveTransport.mosh)
    }

    func testFailedAttachWhileMoshSessionMountedPreservesPriorSession() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let pane = phase4Panes(in: fixture)[0]
        var host = phase4Host()
        host.preferredTransport = .mosh
        let hostFileURL = phase4HostFileURL()
        defer {
            try? FileManager.default.removeItem(
                at: hostFileURL.deletingLastPathComponent()
            )
        }
        let moshTransport = TestRecordingMoshTransport()
        let application = makePhase4NavigationApplication(
            hostFileURL: hostFileURL,
            fixture: fixture,
            moshTransport: moshTransport
        )

        try await application.save(host)
        application.model.connect(to: host)

        try await waitUntil {
            application.model.isPanePickerPresented
                && application.model.connectionState == .connected
        }

        application.model.selectOrdinaryTerminalFromPicker()
        try await waitUntil {
            application.model.herdrState == .ordinaryTerminal
                && !application.model.isPanePickerPresented
        }
        let loginShellSession = try XCTUnwrap(application.model.activeConnection?.session)
        XCTAssertEqual(application.model.activeConnection?.transport, ActiveTransport.mosh)

        await moshTransport.failNextAttach()

        application.model.openPanePickerFromTerminal()
        try await waitUntil { application.model.isPanePickerPresented }

        application.model.selectPaneFromPicker(pane.id)
        try await waitUntil {
            application.model.isPanePickerPresented
                && application.model.panePicker?.message != nil
        }

        XCTAssertTrue(
            application.model.activeConnection?.session === loginShellSession,
            "Failed attach must keep prior on-screen Mosh session alive"
        )
        XCTAssertEqual(application.model.activeConnection?.transport, ActiveTransport.mosh)
        let ptys = await moshTransport.getCreatedPTYs()
        guard let loginPTY = ptys.last else {
            return XCTFail("The ordinary Mosh login shell must remain available")
        }
        let isClosed = await loginPTY.getIsClosed()
        XCTAssertFalse(isClosed, "Prior Mosh PTY must not be closed on failed attach")
    }

    /// A failed SSH control rebuild on Picker open must not tear down the
    /// mounted Mosh terminal or navigate back to Hosts — the Mosh data
    /// plane keeps the session alive independently of SSH.
    func testMoshPathChangeSSHRebuildFailurePreservesMoshTerminalAndDoesNotReturnToHosts() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let pane = phase4Panes(in: fixture)[0]
        var host = phase4Host()
        host.preferredTransport = .mosh
        let hostFileURL = phase4HostFileURL()
        defer {
            try? FileManager.default.removeItem(
                at: hostFileURL.deletingLastPathComponent()
            )
        }
        let client = Phase2SSHClient(
            presentedFingerprint: "SHA256:phase4-test-key",
            outcomes: [false, true]
        )
        let pathMonitor = Phase9NetworkPathMonitor()
        let moshTransport = TestRecordingMoshTransport()
        let application = makePhase4NavigationApplication(
            hostFileURL: hostFileURL,
            fixture: fixture,
            client: client,
            moshTransport: moshTransport,
            networkPathMonitor: pathMonitor
        )

        try await application.save(host)
        application.model.connect(to: host)

        try await waitUntil {
            application.model.isPanePickerPresented
                && application.model.connectionState == .connected
        }

        application.model.selectPaneFromPicker(pane.id)
        try await waitUntil {
            if case let .attached(_, attachedPane) = application.model.herdrState {
                return attachedPane.id == pane.id && !application.model.isPanePickerPresented
            }
            return false
        }

        let moshSession: SSHShellSession = try XCTUnwrap(application.model.activeConnection?.session)
        XCTAssertEqual(application.model.activeConnection?.transport, ActiveTransport.mosh)

        let satisfiedWiFi = NetworkPathSnapshot(
            status: .satisfied,
            interfaces: [.wifi],
            isExpensive: false,
            isConstrained: false
        )
        pathMonitor.emit(satisfiedWiFi)
        try await waitUntil {
            application.model.networkPathRecovery.lastPath == satisfiedWiFi
        }

        let satisfiedCellular = NetworkPathSnapshot(
            status: .satisfied,
            interfaces: [.cellular],
            isExpensive: true,
            isConstrained: false
        )
        pathMonitor.emit(satisfiedCellular)
        try await waitUntil("roam retired ssh control") {
            application.model.networkPathRecovery.controlPlaneNeedsRebuild
        }

        // Opening the Picker triggers the deferred rebuild; the second
        // attempt fails, but the Mosh terminal must stay mounted.
        application.model.openPanePickerFromTerminal()
        try await waitUntil {
            await client.connectionAttempts() == 2
        }
        try await waitUntil("failed rebuild settled") {
            application.model.networkPathRecovery.transparentTask == nil
        }

        XCTAssertNotNil(application.model.activeConnection)
        XCTAssertTrue(
            application.model.activeConnection?.session === moshSession,
            "Mosh terminal session must survive SSH control rebuild failure"
        )
        XCTAssertEqual(application.model.activeConnection?.transport, ActiveTransport.mosh)
        guard case let .attached(_, currentPane) = application.model.herdrState else {
            return XCTFail("Terminal must remain attached even after SSH rebuild failure")
        }
        XCTAssertEqual(currentPane.id, pane.id)
        XCTAssertNil(application.model.errorMessage)
        XCTAssertFalse(application.model.isTearingDown)
    }

    func testSSHOnlyHostAttachStillUsesSSH() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let pane = phase4Panes(in: fixture)[0]
        var host = phase4Host()
        host.preferredTransport = .ssh
        let hostFileURL = phase4HostFileURL()
        defer {
            try? FileManager.default.removeItem(
                at: hostFileURL.deletingLastPathComponent()
            )
        }
        let moshTransport = TestRecordingMoshTransport()
        let application = makePhase4NavigationApplication(
            hostFileURL: hostFileURL,
            fixture: fixture,
            moshTransport: moshTransport
        )

        try await application.save(host)
        application.model.connect(to: host)

        try await waitUntil {
            application.model.isPanePickerPresented
                && application.model.connectionState == .connected
        }

        application.model.selectPaneFromPicker(pane.id)
        try await waitUntil {
            if case let .attached(_, attachedPane) = application.model.herdrState {
                return attachedPane.id == pane.id && !application.model.isPanePickerPresented
            }
            return false
        }

        XCTAssertEqual(application.model.activeConnection?.transport, ActiveTransport.ssh)

        let calls = await moshTransport.getCalls()
        XCTAssertTrue(calls.isEmpty, "Pure SSH host must not invoke Mosh transport")
    }
}

private extension Phase9MoshTerminalTests {
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
