import HerdrKit
import XCTest
@testable import Mudi

final class Phase4MobileInteractionTests: XCTestCase {
    func testReturningFromHerdrListShowsHostsDisconnectsAndHidesPanes() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let host = phase4Host()
        let transport = Phase4TerminalTransport()
        let application = makeMissingPhase4NavigationApplication(
            transport: transport,
            fixture: fixture
        )

        try await application.save(host)
        _ = try await application.connect(to: host)
        let state = await application.returnToHosts()

        if case let .hosts(hosts) = state {
            XCTAssertEqual(hosts, [host])
        } else {
            XCTFail("Returning from Herdr should show the saved Host list")
        }
        let connectedAfterReturn = await application.isConnected()
        let disconnections = await transport.disconnections()
        XCTAssertFalse(connectedAfterReturn)
        XCTAssertEqual(disconnections, 1)
        if case .herdr(.panes) = state {
            XCTFail("Returning to Hosts must not leave the Herdr pane list visible")
        }
    }

    func testAttachedTerminalTitleUsesPaneOrAgentNameInsteadOfHostAddress() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let pane = try XCTUnwrap(phase4Panes(in: fixture).first)
        let host = phase4Host(hostname: "203.0.113.17")
        let application = makeMissingPhase4NavigationApplication(fixture: fixture)

        _ = try await application.connect(to: host)
        let state = await application.selectPane(pane.id)

        guard case let .terminal(attached) = state else {
            XCTFail("Selecting a Herdr pane should produce an attached terminal")
            return
        }
        let allowedTitles = [pane.title, pane.agent?.name].compactMap { $0 }
        XCTAssertTrue(
            allowedTitles.contains(attached.title),
            "The terminal title should come from the selected pane or agent"
        )
        XCTAssertNotEqual(attached.title, host.hostname)
    }

    func testColdStartKeepsSavedHostsWithoutImplicitlyRestoringLastPane() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let pane = try XCTUnwrap(phase4Panes(in: fixture).last)
        let host = phase4Host()
        let hostFile = Phase4HostFile()
        let firstLaunch = makeMissingPhase4NavigationApplication(
            hostFile: hostFile,
            fixture: fixture
        )
        try await firstLaunch.save(host)

        let transport = Phase4TerminalTransport()
        let application = makeMissingPhase4NavigationApplication(
            hostFile: hostFile,
            transport: transport,
            fixture: fixture,
            rememberedPaneID: pane.id
        )

        let state = await application.coldStart()
        let loadedHosts = try await application.loadHosts()
        XCTAssertEqual(loadedHosts, [host])
        if case let .hosts(hosts) = state {
            XCTAssertEqual(hosts, [host])
        } else {
            XCTFail("A cold start should begin at the saved Host list")
        }
        _ = try await application.connect(to: host)
        let attachmentsBeforeRestore = await transport.attachments()
        let connectedBeforeRestore = await application.isConnected()
        XCTAssertTrue(attachmentsBeforeRestore.isEmpty)
        XCTAssertTrue(connectedBeforeRestore)

        _ = await application.restoreLastPane()
        let attachmentsAfterRestore = await transport.attachments()
        XCTAssertEqual(attachmentsAfterRestore, [pane])
    }
}
