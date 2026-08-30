import HerdrKit
import XCTest
@testable import Mudi

@MainActor
final class Phase4MobileInteractionTests: XCTestCase {
    func testReturningFromHerdrListShowsHostsDisconnectsAndHidesPanes() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let host = phase4Host()
        let hostFileURL = phase4HostFileURL()
        defer { try? FileManager.default.removeItem(at: hostFileURL.deletingLastPathComponent()) }
        let application = makePhase4NavigationApplication(
            hostFileURL: hostFileURL,
            fixture: fixture
        )

        try await application.save(host)
        application.model.connect(to: host)
        let connected = await waitForRootViewCondition {
            guard case .panes = application.model.herdrState else { return false }
            return application.model.activeConnection != nil
        }
        XCTAssertTrue(connected)

        let stateStream = await application.coordinator.connectionStateStream()
        let disconnectObserved = Task {
            await waitForCoordinatorDisconnect(on: stateStream)
        }
        application.model.returnToHosts()
        XCTAssertTrue(application.model.isTearingDown)
        let returned = await waitForRootViewCondition {
            application.model.herdrState == nil
                && application.model.activeConnection == nil
                && application.model.isTearingDown
        }
        XCTAssertTrue(returned)
        XCTAssertEqual(application.model.hosts, [host])

        // A host tap can arrive while the Hosts screen is being presented.
        // It must queue behind the real SSH teardown rather than being dropped
        // because the previous connection is still marked connected.
        application.model.connect(to: host)
        let coordinatorDisconnected = await disconnectObserved.value
        XCTAssertTrue(coordinatorDisconnected)
        let reconnected = await waitForRootViewCondition {
            guard case .panes = application.model.herdrState else { return false }
            return application.model.connectionState == .connected
        }
        XCTAssertTrue(reconnected)
        let reconnectedState = await application.coordinator.connectionState()
        XCTAssertEqual(reconnectedState, .connected)

        application.model.disconnect()
        let disconnectedAgain = await waitForCoordinatorState(
            application.coordinator,
            expected: .disconnected
        )
        XCTAssertTrue(disconnectedAgain)
    }

    func testAttachedTerminalTitleUsesPaneOrAgentNameInsteadOfHostAddress() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let pane = try XCTUnwrap(phase4Panes(in: fixture).first)
        let host = phase4Host(hostname: "203.0.113.17")
        let hostFileURL = phase4HostFileURL()
        defer { try? FileManager.default.removeItem(at: hostFileURL.deletingLastPathComponent()) }
        let application = makePhase4NavigationApplication(
            hostFileURL: hostFileURL,
            fixture: fixture
        )

        try await application.save(host)
        application.model.connect(to: host)
        let discovered = await waitForRootViewCondition {
            guard case .panes = application.model.herdrState else { return false }
            return application.model.activeConnection != nil
        }
        XCTAssertTrue(discovered)

        application.model.selectPane(pane.id)
        let attached = await waitForRootViewCondition {
            if case .attached = application.model.herdrState {
                return application.model.activeConnection?.terminalTitle != nil
            }
            return false
        }
        XCTAssertTrue(attached)

        let terminalTitle = try XCTUnwrap(application.model.activeConnection?.terminalTitle)
        let allowedTitles = [pane.title, pane.agent?.name].compactMap { $0 }
        XCTAssertTrue(allowedTitles.contains(terminalTitle))
        XCTAssertNotEqual(terminalTitle, host.hostname)

        application.model.disconnect()
        _ = await waitForRootViewCondition {
            application.model.connectionState == .disconnected
        }
    }

    func testColdStartKeepsSavedHostsWithoutImplicitlyRestoringLastPane() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let pane = try XCTUnwrap(phase4Panes(in: fixture).last)
        let host = phase4Host()
        let hostFileURL = phase4HostFileURL()
        defer { try? FileManager.default.removeItem(at: hostFileURL.deletingLastPathComponent()) }
        let credentials = Phase4CredentialVault()
        let knownHostKeys = Phase4KnownHostKeys()
        let firstLaunch = makePhase4NavigationApplication(
            hostFileURL: hostFileURL,
            fixture: fixture,
            credentialVault: credentials,
            knownHostKeys: knownHostKeys
        )
        try await firstLaunch.save(host)

        let transport = Phase4TerminalTransport()
        let application = makePhase4NavigationApplication(
            hostFileURL: hostFileURL,
            fixture: fixture,
            transport: transport,
            credentialVault: credentials,
            knownHostKeys: knownHostKeys,
            rememberedPaneID: pane.id,
            rememberedPaneHostID: host.id
        )

        await application.coldStart()
        XCTAssertEqual(application.model.hosts, [host])
        XCTAssertNil(application.model.herdrState)
        XCTAssertNil(application.model.activeConnection)

        application.model.connect(to: host)
        let discovered = await waitForRootViewCondition {
            guard case .panes = application.model.herdrState else { return false }
            return application.model.connectionState == .connected
        }
        XCTAssertTrue(discovered)
        let attachmentsBeforeRestore = await transport.attachments()
        XCTAssertTrue(attachmentsBeforeRestore.isEmpty)

        application.model.restoreLastPane()
        let restored = await waitForRootViewCondition {
            if case let .attached(_, attachedPane) = application.model.herdrState {
                return attachedPane.id == pane.id
            }
            return false
        }
        XCTAssertTrue(restored)
        let attachmentsAfterRestore = await transport.attachments()
        XCTAssertEqual(attachmentsAfterRestore, [pane])

        application.model.disconnect()
        _ = await waitForRootViewCondition {
            application.model.connectionState == .disconnected
        }
    }

    private func waitForRootViewCondition(
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    private func waitForCoordinatorState(
        _ coordinator: ApplicationCoordinator,
        expected: ConnectionState
    ) async -> Bool {
        for _ in 0..<200 {
            if await coordinator.connectionState() == expected { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await coordinator.connectionState() == expected
    }

    private func waitForCoordinatorDisconnect(
        on stream: AsyncStream<ConnectionState>
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await state in stream {
                    if state == .disconnected { return true }
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }
}
