import XCTest
@testable import Mudi

@MainActor
final class RootViewTests: XCTestCase {
    func testApplicationSkeletonLoads() {
        _ = RootView()
    }

    func testRootHostConnectionPresentsPickerAndDismissalDisconnectsHost() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let host = phase4Host()
        let hostFileURL = phase4HostFileURL()
        defer {
            try? FileManager.default.removeItem(
                at: hostFileURL.deletingLastPathComponent()
            )
        }
        let application = makePhase4NavigationApplication(
            hostFileURL: hostFileURL,
            fixture: fixture
        )

        try await application.save(host)
        application.model.connect(to: host)
        let pickerPresented = await waitForRootViewCondition {
            application.model.isPanePickerPresented
                && application.model.panePicker?.origin == .host
        }
        XCTAssertTrue(pickerPresented)
        XCTAssertNotNil(application.model.activeConnection)

        application.model.panePickerPresentationBindingDidChange(
            false,
            sceneIsActive: true
        )
        application.model.panePickerPresentationBindingDidChange(
            false,
            sceneIsActive: true
        )
        await application.model.dismissPanePickerAndWait()
        let disconnected = await waitForRootViewCondition {
            application.model.activeConnection == nil
                && !application.model.isTearingDown
                && application.model.connectionState == .disconnected
        }
        XCTAssertTrue(disconnected)
    }

    func testTerminalOriginSystemDismissalUsesExplicitSemanticsAndRetainsContext() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let oldPane = try XCTUnwrap(phase4Panes(in: fixture).first)
        let host = phase4Host()
        let hostFileURL = phase4HostFileURL()
        defer {
            try? FileManager.default.removeItem(
                at: hostFileURL.deletingLastPathComponent()
            )
        }
        let application = makePhase4NavigationApplication(
            hostFileURL: hostFileURL,
            fixture: fixture
        )

        try await application.save(host)
        application.model.connect(to: host)
        let hostPickerPresented = await waitForRootViewCondition {
            application.model.isPanePickerPresented
        }
        XCTAssertTrue(hostPickerPresented)

        application.model.selectPaneFromPicker(oldPane.id)
        let terminalAttached = await waitForRootViewCondition {
            guard case let .attached(_, pane) = application.model.herdrState else {
                return false
            }
            return pane.id == oldPane.id
                && !application.model.isPanePickerPresented
        }
        XCTAssertTrue(terminalAttached)

        application.model.openPanePickerFromTerminal()
        let terminalPickerPresented = await waitForRootViewCondition {
            guard let picker = application.model.panePicker else { return false }
            return application.model.isPanePickerPresented
                && picker.origin == .terminal
                && picker.attachedTerminal?.pane.id == oldPane.id
        }
        XCTAssertTrue(terminalPickerPresented)

        application.model.panePickerPresentationBindingDidChange(
            false,
            sceneIsActive: true
        )
        await application.model.dismissPanePickerAndWait()
        let restored = await waitForRootViewCondition {
            guard case let .attached(_, pane) = application.model.herdrState else {
                return false
            }
            return pane.id == oldPane.id
                && !application.model.isPanePickerPresented
        }
        XCTAssertTrue(restored)
        XCTAssertEqual(application.model.activeConnection?.host.id, host.id)
        let connectionState = await application.coordinator.connectionState()
        XCTAssertEqual(connectionState, .connected)
    }

    func testHostPickerSurvivesBackgroundForegroundWithoutDisconnecting() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let host = phase4Host()
        let hostFileURL = phase4HostFileURL()
        defer {
            try? FileManager.default.removeItem(
                at: hostFileURL.deletingLastPathComponent()
            )
        }
        let scheduler = Phase6TestScheduler()
        let application = makePhase4NavigationApplication(
            hostFileURL: hostFileURL,
            fixture: fixture,
            panePickerScheduler: scheduler
        )

        try await application.save(host)
        application.model.connect(to: host)
        let pickerPresented = await waitForRootViewCondition {
            application.model.isPanePickerPresented
                && application.model.panePicker?.origin == .host
                && application.model.activeConnection != nil
                && application.model.connectionState == .connected
        }
        XCTAssertTrue(pickerPresented)
        XCTAssertNotNil(application.model.activeConnection)
        let initialScheduledJobCount = await scheduler.scheduledJobCount()
        XCTAssertEqual(initialScheduledJobCount, 1)

        application.model.sceneWillResignActive()
        application.model.panePickerPresentationBindingDidChange(
            false,
            sceneIsActive: false
        )
        XCTAssertTrue(application.model.isPanePickerPresented)
        XCTAssertNotNil(application.model.activeConnection)

        await application.model.sceneDidEnterBackground()
        // The native system sheet persists across backgrounding; the model
        // leaves presentation state untouched and only suspends refresh.
        XCTAssertTrue(application.model.isPanePickerPresented)
        XCTAssertNotNil(application.model.panePicker)
        XCTAssertNotNil(application.model.activeConnection)
        let backgroundScheduledJobCount = await scheduler.scheduledJobCount()
        XCTAssertEqual(backgroundScheduledJobCount, 0)
        let backgroundConnectionState = await application.coordinator.connectionState()
        XCTAssertEqual(backgroundConnectionState, .connected)

        // Scene interruption does not take the explicit Host Close path.
        await application.model.sceneDidBecomeActive()
        XCTAssertTrue(application.model.isPanePickerPresented)
        XCTAssertNotNil(application.model.panePicker)
        XCTAssertNotNil(application.model.activeConnection)
        let foregroundScheduledJobCount = await scheduler.scheduledJobCount()
        XCTAssertEqual(foregroundScheduledJobCount, 1)
        let hostConnectionState = await application.coordinator.connectionState()
        XCTAssertEqual(hostConnectionState, .connected)
    }

    func testTerminalPickerSurvivesBackgroundForegroundOverSameTerminal() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let oldPane = try XCTUnwrap(phase4Panes(in: fixture).first)
        let host = phase4Host()
        let hostFileURL = phase4HostFileURL()
        defer {
            try? FileManager.default.removeItem(
                at: hostFileURL.deletingLastPathComponent()
            )
        }
        let scheduler = Phase6TestScheduler()
        let application = makePhase4NavigationApplication(
            hostFileURL: hostFileURL,
            fixture: fixture,
            panePickerScheduler: scheduler
        )

        try await application.save(host)
        application.model.connect(to: host)
        let hostPickerPresented = await waitForRootViewCondition {
            application.model.isPanePickerPresented
        }
        XCTAssertTrue(hostPickerPresented)

        application.model.selectPaneFromPicker(oldPane.id)
        let terminalAttached = await waitForRootViewCondition {
            guard case let .attached(_, pane) = application.model.herdrState else {
                return false
            }
            return pane.id == oldPane.id
                && !application.model.isPanePickerPresented
        }
        XCTAssertTrue(terminalAttached)

        application.model.openPanePickerFromTerminal()
        let terminalPickerPresented = await waitForRootViewCondition {
            guard let picker = application.model.panePicker else { return false }
            return application.model.isPanePickerPresented
                && picker.origin == .terminal
                && picker.attachedTerminal?.pane.id == oldPane.id
        }
        XCTAssertTrue(terminalPickerPresented)
        let terminalPickerScheduledJobCount = await scheduler.scheduledJobCount()
        XCTAssertEqual(terminalPickerScheduledJobCount, 1)

        application.model.sceneWillResignActive()
        await application.model.sceneDidEnterBackground()
        let terminalBackgroundSuspended = await waitForRootViewCondition {
            guard case let .attached(_, pane) = application.model.herdrState else {
                return false
            }
            return application.model.isPanePickerPresented
                && application.model.panePicker?.origin == .terminal
                && application.model.isPaneControlSuspended
                && pane.id == oldPane.id
        }
        XCTAssertTrue(terminalBackgroundSuspended)
        let terminalBackgroundScheduledJobCount = await scheduler.scheduledJobCount()
        XCTAssertEqual(terminalBackgroundScheduledJobCount, 0)
        XCTAssertEqual(application.model.activeConnection?.host.id, host.id)

        await application.model.sceneDidBecomeActive()
        XCTAssertTrue(application.model.isPanePickerPresented)
        XCTAssertNotNil(application.model.panePicker)
        XCTAssertFalse(application.model.isPaneControlSuspended)
        guard case let .attached(_, resumedPane) = application.model.herdrState else {
            XCTFail("Foregrounding should retain the attached terminal context")
            return
        }
        XCTAssertEqual(resumedPane.id, oldPane.id)
        XCTAssertEqual(
            application.model.panePicker?.attachedTerminal?.pane.id,
            oldPane.id
        )
        XCTAssertEqual(application.model.activeConnection?.host.id, host.id)
        let terminalForegroundScheduledJobCount = await scheduler.scheduledJobCount()
        XCTAssertEqual(terminalForegroundScheduledJobCount, 1)
    }

    func testFailedForegroundResumeRecoversThroughPickerInsteadOfStranding() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let oldPane = try XCTUnwrap(phase4Panes(in: fixture).first)
        let host = phase4Host()
        let hostFileURL = phase4HostFileURL()
        defer {
            try? FileManager.default.removeItem(
                at: hostFileURL.deletingLastPathComponent()
            )
        }
        let transport = Phase4TerminalTransport()
        let application = makePhase4NavigationApplication(
            hostFileURL: hostFileURL,
            fixture: fixture,
            transport: transport
        )

        try await application.save(host)
        application.model.connect(to: host)
        let hostPickerPresented = await waitForRootViewCondition {
            application.model.isPanePickerPresented
        }
        XCTAssertTrue(hostPickerPresented)

        application.model.selectPaneFromPicker(oldPane.id)
        let terminalAttached = await waitForRootViewCondition {
            guard case let .attached(_, pane) = application.model.herdrState else {
                return false
            }
            return pane.id == oldPane.id
        }
        XCTAssertTrue(terminalAttached)

        application.model.sceneWillResignActive()
        await application.model.sceneDidEnterBackground()
        XCTAssertTrue(application.model.isPaneControlSuspended)

        // The pane/control channel does not survive the interruption (e.g.
        // device auto-lock dropped the connection), so the retake fails.
        await transport.setMissingPaneIDs([oldPane.id])
        await application.model.sceneDidBecomeActive()

        // A failed resume must recover through the Picker instead of
        // stranding the UI on a dead browser surface.
        let recovered = await waitForRootViewCondition {
            guard application.model.herdrState == .ordinaryTerminal,
                  let picker = application.model.panePicker
            else { return false }
            return application.model.isPanePickerPresented
                && picker.origin == .terminal
                && !application.model.isPaneControlSuspended
        }
        XCTAssertTrue(recovered)
        XCTAssertEqual(application.model.activeConnection?.host.id, host.id)
        let connectionState = await application.coordinator.connectionState()
        XCTAssertEqual(connectionState, .connected)
    }

    func testAttachedTerminalNormalCloseReturnsToPickerAndRefreshes() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let oldPane = try XCTUnwrap(phase4Panes(in: fixture).first)
        let host = phase4Host()
        let hostFileURL = phase4HostFileURL()
        defer {
            try? FileManager.default.removeItem(
                at: hostFileURL.deletingLastPathComponent()
            )
        }
        let scheduler = Phase6TestScheduler()
        let application = makePhase4NavigationApplication(
            hostFileURL: hostFileURL,
            fixture: fixture,
            panePickerScheduler: scheduler
        )

        try await application.save(host)
        application.model.connect(to: host)
        let hostPickerPresented = await waitForRootViewCondition {
            application.model.isPanePickerPresented
        }
        XCTAssertTrue(hostPickerPresented)

        application.model.selectPaneFromPicker(oldPane.id)
        let attached = await waitForRootViewCondition {
            guard case let .attached(_, pane) = application.model.herdrState else {
                return false
            }
            return pane.id == oldPane.id
        }
        XCTAssertTrue(attached)
        let session = try XCTUnwrap(application.model.activeConnection?.session)

        await application.model.handleTerminalSessionClosed(
            for: ObjectIdentifier(session)
        )

        XCTAssertTrue(application.model.isPanePickerPresented)
        XCTAssertEqual(application.model.panePicker?.origin, .terminal)
        XCTAssertNil(
            application.model.panePicker?.attachedTerminal,
            "A closed control pane must not be restored by Picker dismissal"
        )
        XCTAssertEqual(application.model.herdrState, .ordinaryTerminal)
        XCTAssertNil(application.model.errorMessage)
        let scheduledJobCount = await scheduler.scheduledJobCount()
        XCTAssertEqual(scheduledJobCount, 1)
        let connectionState = await application.coordinator.connectionState()
        XCTAssertEqual(connectionState, .connected)

        await application.model.dismissPanePickerAndWait()
        let dismissedWithoutLoop = await waitForRootViewCondition {
            !application.model.isPanePickerPresented
                && application.model.herdrState == .ordinaryTerminal
        }
        XCTAssertTrue(dismissedWithoutLoop)
        XCTAssertNil(application.model.panePicker)
        let dismissedScheduledJobCount = await scheduler.scheduledJobCount()
        XCTAssertEqual(dismissedScheduledJobCount, 0)
    }

    func testAttachedTerminalNormalCloseWhilePickerVisibleClearsDeadContext() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let oldPane = try XCTUnwrap(phase4Panes(in: fixture).first)
        let host = phase4Host()
        let hostFileURL = phase4HostFileURL()
        defer {
            try? FileManager.default.removeItem(
                at: hostFileURL.deletingLastPathComponent()
            )
        }
        let scheduler = Phase6TestScheduler()
        let application = makePhase4NavigationApplication(
            hostFileURL: hostFileURL,
            fixture: fixture,
            panePickerScheduler: scheduler
        )

        try await application.save(host)
        application.model.connect(to: host)
        let hostPickerPresented = await waitForRootViewCondition {
            application.model.isPanePickerPresented
        }
        XCTAssertTrue(hostPickerPresented)

        application.model.selectPaneFromPicker(oldPane.id)
        let attached = await waitForRootViewCondition {
            guard case let .attached(_, pane) = application.model.herdrState else {
                return false
            }
            return pane.id == oldPane.id
        }
        XCTAssertTrue(attached)
        application.model.openPanePickerFromTerminal()
        let terminalPickerPresented = await waitForRootViewCondition {
            guard let picker = application.model.panePicker else { return false }
            return application.model.isPanePickerPresented
                && picker.origin == .terminal
                && picker.attachedTerminal?.pane.id == oldPane.id
        }
        XCTAssertTrue(terminalPickerPresented)
        let session = try XCTUnwrap(application.model.activeConnection?.session)

        await application.model.handleTerminalSessionClosed(
            for: ObjectIdentifier(session)
        )

        XCTAssertTrue(application.model.isPanePickerPresented)
        XCTAssertEqual(application.model.panePicker?.origin, .terminal)
        XCTAssertNil(application.model.panePicker?.attachedTerminal)
        XCTAssertEqual(application.model.herdrState, .ordinaryTerminal)
        XCTAssertNil(application.model.errorMessage)

        await application.model.dismissPanePickerAndWait()
        let dismissedWithoutLoop = await waitForRootViewCondition {
            !application.model.isPanePickerPresented
                && application.model.herdrState == .ordinaryTerminal
        }
        XCTAssertTrue(dismissedWithoutLoop)
        XCTAssertNil(application.model.panePicker)
    }

    func testMoshOrdinaryTerminalNormalCloseReturnsToPicker() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        var host = phase4Host()
        host.preferredTransport = .mosh
        let hostFileURL = phase4HostFileURL()
        defer {
            try? FileManager.default.removeItem(
                at: hostFileURL.deletingLastPathComponent()
            )
        }
        let scheduler = Phase6TestScheduler()
        let application = makePhase4NavigationApplication(
            hostFileURL: hostFileURL,
            fixture: fixture,
            moshTransport: Phase4MoshTransport(),
            panePickerScheduler: scheduler
        )

        try await application.save(host)
        application.model.connect(to: host)
        let hostPickerPresented = await waitForRootViewCondition {
            application.model.isPanePickerPresented
                && application.model.activeConnection != nil
                && application.model.connectionState == .connected
        }
        XCTAssertTrue(hostPickerPresented)

        application.model.selectOrdinaryTerminalFromPicker()
        let ordinaryTerminal = await waitForRootViewCondition {
            application.model.herdrState == .ordinaryTerminal
                && !application.model.isPanePickerPresented
        }
        XCTAssertTrue(ordinaryTerminal)
        let session = try XCTUnwrap(application.model.activeConnection?.session)

        await application.model.handleTerminalSessionClosed(
            for: ObjectIdentifier(session)
        )

        XCTAssertTrue(application.model.isPanePickerPresented)
        XCTAssertEqual(application.model.panePicker?.origin, .terminal)
        XCTAssertNil(application.model.errorMessage)
        let scheduledJobCount = await scheduler.scheduledJobCount()
        XCTAssertEqual(scheduledJobCount, 1)
        let connectionState = await application.coordinator.connectionState()
        XCTAssertEqual(connectionState, .connected)
    }

    func testOrdinaryTerminalNormalCloseReturnsToHostsWithOneConnectionError() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let host = phase4Host()
        let hostFileURL = phase4HostFileURL()
        defer {
            try? FileManager.default.removeItem(
                at: hostFileURL.deletingLastPathComponent()
            )
        }
        let application = makePhase4NavigationApplication(
            hostFileURL: hostFileURL,
            fixture: fixture
        )

        try await application.save(host)
        application.model.connect(to: host)
        let hostPickerPresented = await waitForRootViewCondition {
            application.model.isPanePickerPresented
                && application.model.activeConnection != nil
                && application.model.connectionState == .connected
        }
        XCTAssertTrue(hostPickerPresented)

        application.model.selectOrdinaryTerminalFromPicker()
        let ordinaryTerminal = await waitForRootViewCondition {
            application.model.herdrState == .ordinaryTerminal
                && !application.model.isPanePickerPresented
        }
        XCTAssertTrue(ordinaryTerminal)
        let session = try XCTUnwrap(application.model.activeConnection?.session)

        await application.model.handleTerminalSessionClosed(
            for: ObjectIdentifier(session)
        )

        XCTAssertFalse(application.model.isPanePickerPresented)
        XCTAssertNil(application.model.activeConnection)
        XCTAssertEqual(
            application.model.errorMessage,
            "The SSH shell connection was lost."
        )
        let disconnected = await waitForRootViewCondition {
            application.model.connectionState == .disconnected
                && !application.model.isTearingDown
        }
        XCTAssertTrue(disconnected)
    }

    func testRootFailedTerminalPaneSwitchRestoresOldTerminalAndRestartsPickerRefresh() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let panes = phase4Panes(in: fixture)
        let oldPane = try XCTUnwrap(panes.first)
        let newPane = try XCTUnwrap(panes.dropFirst().first)
        let host = phase4Host()
        let hostFileURL = phase4HostFileURL()
        defer {
            try? FileManager.default.removeItem(
                at: hostFileURL.deletingLastPathComponent()
            )
        }
        let scheduler = Phase6TestScheduler()
        let transport = Phase4TerminalTransport(
            missingPaneIDs: [newPane.id]
        )
        let application = makePhase4NavigationApplication(
            hostFileURL: hostFileURL,
            fixture: fixture,
            transport: transport,
            panePickerScheduler: scheduler
        )

        try await application.save(host)
        application.model.connect(to: host)
        let hostPickerPresented = await waitForRootViewCondition {
            application.model.isPanePickerPresented
        }
        XCTAssertTrue(hostPickerPresented)

        application.model.selectPaneFromPicker(oldPane.id)
        let oldPaneAttached = await waitForRootViewCondition {
            guard case let .attached(_, pane) = application.model.herdrState else {
                return false
            }
            return pane.id == oldPane.id
        }
        XCTAssertTrue(oldPaneAttached)

        application.model.openPanePickerFromTerminal()
        let terminalPickerPresented = await waitForRootViewCondition {
            guard let picker = application.model.panePicker else { return false }
            return picker.origin == .terminal
                && picker.attachedTerminal?.pane.id == oldPane.id
        }
        XCTAssertTrue(terminalPickerPresented)

        application.model.selectPaneFromPicker(newPane.id)
        let failureShown = await waitForRootViewCondition {
            application.model.panePicker?.message != nil
        }
        XCTAssertTrue(failureShown)

        let attachments = await transport.attachments().map(\.id)
        XCTAssertEqual(
            attachments,
            [oldPane.id, newPane.id, oldPane.id],
            "A failed takeover must reattach the previous pane"
        )
        let scheduledJobCount = await scheduler.scheduledJobCount()
        XCTAssertEqual(
            scheduledJobCount,
            1,
            "A picker that remains visible after failure must resume refresh"
        )

        await application.model.dismissPanePickerAndWait()
        let restored = await waitForRootViewCondition {
            guard case let .attached(_, pane) = application.model.herdrState else {
                return false
            }
            return pane.id == oldPane.id
                && !application.model.isPanePickerPresented
        }
        XCTAssertTrue(restored)
        XCTAssertNotNil(application.model.activeConnection)

        application.model.disconnect()
        _ = await waitForRootViewCondition {
            application.model.connectionState == .disconnected
        }
    }

    func testFailedConnectionDismissesHostKeyPromptAndRejectsLateAccept() async throws {
        let host = phase2Host()
        let knownHostKeys = Phase2KnownHostKeys()
        let callbackStarted = Phase2ConnectionGate()
        let failureGate = Phase2ConnectionGate()
        let client = Phase2SSHClient(
            presentedFingerprint: "SHA256:late-key",
            callbackStartedGate: callbackStarted,
            failureGate: failureGate,
            failAfterStartingHostKeyDecision: true
        )
        let application = makeMissingPhase2Application(
            knownHostKeys: knownHostKeys,
            client: client
        )
        let credentials = phase2Credentials()
        try await application.save(host)
        try await application.save(credentials, for: host)
        let model = RootViewModel(coordinator: application)

        model.connect(to: host)
        await callbackStarted.waitUntilStarted()
        let promptShown = await waitForRootViewCondition { model.hostKeyPrompt != nil }
        XCTAssertTrue(promptShown)
        await failureGate.release()
        let connectionFailed = await waitForRootViewCondition { model.connectionState == .failed }
        XCTAssertTrue(connectionFailed)
        XCTAssertNil(model.hostKeyPrompt)

        model.answerHostKeyPrompt(.accept)
        try await Task.sleep(nanoseconds: 10_000_000)

        let rememberedFingerprint = await knownHostKeys.fingerprint(for: host)
        XCTAssertNil(rememberedFingerprint)
    }

    func testReconnectUsesFreshHostKeyPromptAfterFirstAttemptFailed() async throws {
        let host = phase2Host()
        let knownHostKeys = Phase2KnownHostKeys()
        let callbackStarted = Phase2ConnectionGate()
        let failureGate = Phase2ConnectionGate()
        let client = Phase2SSHClient(
            presentedFingerprint: "SHA256:reconnect-key",
            callbackStartedGate: callbackStarted,
            failureGate: failureGate,
            failAfterStartingHostKeyDecision: true
        )
        let application = makeMissingPhase2Application(
            knownHostKeys: knownHostKeys,
            client: client
        )
        try await application.save(host)
        try await application.save(phase2Credentials(), for: host)
        let model = RootViewModel(coordinator: application)

        model.connect(to: host)
        await callbackStarted.waitUntilStarted()
        let firstPromptShown = await waitForRootViewCondition { model.hostKeyPrompt != nil }
        XCTAssertTrue(firstPromptShown)
        model.answerHostKeyPrompt(.reject)
        await failureGate.release()
        let firstConnectionFailed = await waitForRootViewCondition { model.connectionState == .failed }
        XCTAssertTrue(firstConnectionFailed)
        let rememberedAfterRejection = await knownHostKeys.fingerprint(for: host)
        XCTAssertNil(rememberedAfterRejection)

        model.reconnect()
        let reconnectPromptShown = await waitForRootViewCondition { model.hostKeyPrompt != nil }
        XCTAssertTrue(reconnectPromptShown)
        model.answerHostKeyPrompt(.accept)

        let reconnected = await waitForRootViewCondition { model.connectionState == .connected }
        XCTAssertTrue(reconnected)
        let rememberedAfterReconnect = await knownHostKeys.fingerprint(for: host)
        XCTAssertEqual(rememberedAfterReconnect, "SHA256:reconnect-key")
    }

    func testDeletingActiveHostDismissesHostKeyPrompt() async throws {
        let host = phase2Host()
        let client = Phase2SSHClient(presentedFingerprint: "SHA256:pending-key")
        let application = makeMissingPhase2Application(client: client)
        try await application.save(host)
        try await application.save(phase2Credentials(), for: host)
        let model = RootViewModel(coordinator: application)

        model.connect(to: host)
        let promptShown = await waitForRootViewCondition { model.hostKeyPrompt != nil }
        XCTAssertTrue(promptShown)

        model.delete(host)
        let hostsDeleted = await waitForRootViewCondition { model.hosts.isEmpty }
        XCTAssertTrue(hostsDeleted)
        XCTAssertNil(model.hostKeyPrompt)

        model.answerHostKeyPrompt(.reject)
    }

    private func waitForRootViewCondition(
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<200 {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }
}
