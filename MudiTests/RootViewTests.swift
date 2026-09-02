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

        application.model.dismissPanePicker()
        let disconnected = await waitForRootViewCondition {
            application.model.activeConnection == nil
                && !application.model.isTearingDown
                && application.model.connectionState == .disconnected
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

        application.model.dismissPanePicker()
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
