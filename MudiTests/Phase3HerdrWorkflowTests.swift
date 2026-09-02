import Foundation
import HerdrKit
import XCTest
@testable import Mudi

final class Phase3HerdrWorkflowTests: XCTestCase {
    func testNoRunningSessionOffersOrdinarySSHPathWithoutPaneAttach() async throws {
        let host = phase3Host()
        let fixture = try Phase3HerdrFixtures.empty()
        let transport = Phase3TerminalTransport()
        let application = makePhase3Application(
            fixture: fixture,
            transport: transport
        )

        XCTAssertTrue(fixture.sessions.isEmpty)
        let browserState = try await application.discover(on: host)
        guard case .empty = browserState else {
            XCTFail("A session list with no running sessions should show the empty state")
            return
        }

        let discoveryRequests = await application.discovery.requests()
        XCTAssertEqual(discoveryRequests, [host])
        let attachmentsBeforeTerminal = await transport.attachments()
        XCTAssertTrue(attachmentsBeforeTerminal.isEmpty)

        let terminalState = try await application.openOrdinaryTerminal()
        guard case .ordinaryTerminal = terminalState else {
            XCTFail("No running Herdr session should offer the ordinary SSH terminal")
            return
        }

        let connections = await transport.connections()
        XCTAssertEqual(connections, [host])
        let attachmentsAfterTerminal = await transport.attachments()
        XCTAssertTrue(attachmentsAfterTerminal.isEmpty)
    }

    func testOneRunningSessionSkipsSessionPickerAndListsRecordedPanesAndAgents() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let session = try recordedSession(in: fixture, id: "default")
        let agentPane = try recordedPane(in: session, id: "w55:p1")
        let shellPane = try recordedPane(in: session, id: "w56:p1")
        let application = makePhase3Application(fixture: fixture)

        XCTAssertTrue(session.isDefault)
        XCTAssertEqual(session.workspaces.first?.name, "mudiapp")
        XCTAssertEqual(agentPane.agent?.name, "pi")
        XCTAssertEqual(agentPane.agent?.state, .idle)
        XCTAssertNil(shellPane.agent)

        let browserState = try await application.discover(on: phase3Host())
        guard case let .panes(listedSession, message) = browserState else {
            XCTFail("One running Herdr session should open its pane list without a session picker")
            return
        }

        XCTAssertNil(message)
        XCTAssertEqual(listedSession, session)
        XCTAssertEqual(phase3Panes(in: listedSession), phase3Panes(in: session))
        XCTAssertEqual(phase3Panes(in: listedSession).first?.agent, agentPane.agent)
    }

    func testMultipleRunningSessionsListsSessionsBeforeShowingAnySessionPanes() async throws {
        let fixture = try Phase3HerdrFixtures.multiple()
        let firstSession = try recordedSession(in: fixture, id: "default")
        let secondSession = try recordedSession(in: fixture, id: "phase3-cli-fixture")
        let firstPane = try recordedPane(in: firstSession, id: "w55:p1")
        let secondDefaultPane = try recordedPane(in: firstSession, id: "w56:p1")
        let thirdDefaultPane = try recordedPane(in: firstSession, id: "w5R:p1")
        let fourthDefaultPane = try recordedPane(in: firstSession, id: "w5R:p2")
        let secondPane = try recordedPane(in: secondSession, id: "w1:p1")
        let application = makePhase3Application(fixture: fixture)

        let initialState = try await application.discover(on: phase3Host())
        guard case let .sessions(summaries) = initialState else {
            XCTFail("Multiple running Herdr sessions should show a session list first")
            return
        }
        XCTAssertEqual(
            summaries,
            [
                Phase3SessionSummary(session: firstSession),
                Phase3SessionSummary(session: secondSession),
            ]
        )

        let paneBeforeSessionSelection = await application.selectPane(secondPane.id)
        guard case let .sessions(summariesAfterPaneAttempt) = paneBeforeSessionSelection else {
            XCTFail("A pane must not be shown or attached before its session is selected")
            return
        }
        XCTAssertEqual(summariesAfterPaneAttempt, summaries)
        let attachmentsBeforeSessionSelection = await application.transport.attachments()
        XCTAssertTrue(attachmentsBeforeSessionSelection.isEmpty)

        let selectedState = await application.selectSession(firstSession.id)
        guard case let .panes(listedSession, message) = selectedState else {
            XCTFail("Selecting a session should show only that session's pane list")
            return
        }
        XCTAssertNil(message)
        XCTAssertEqual(listedSession, firstSession)
        XCTAssertEqual(
            phase3Panes(in: listedSession),
            [firstPane, secondDefaultPane, thirdDefaultPane, fourthDefaultPane]
        )
        XCTAssertFalse(phase3Panes(in: listedSession).contains(secondPane))
    }

    func testListingPanesDoesNotAutomaticallyAttachOne() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let session = try recordedSession(in: fixture, id: "default")
        let pane = try recordedPane(in: session, id: "w55:p1")
        let transport = Phase3TerminalTransport()
        let application = makePhase3Application(
            fixture: fixture,
            transport: transport
        )

        let state = try await application.discover(on: phase3Host())
        guard case let .panes(listedSession, _) = state else {
            XCTFail("The one-session discovery should list panes")
            return
        }
        XCTAssertTrue(phase3Panes(in: listedSession).contains(pane))

        let attachments = await transport.attachments()
        XCTAssertTrue(attachments.isEmpty)
    }

    func testSelectingPaneAttachesOnlyAfterUserSelectsThatPane() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let session = try recordedSession(in: fixture, id: "default")
        let panes = phase3Panes(in: session)
        let firstPane = try XCTUnwrap(panes.first)
        let selectedPane = try XCTUnwrap(panes.dropFirst().first)
        let transport = Phase3TerminalTransport()
        let application = makePhase3Application(
            fixture: fixture,
            transport: transport
        )

        _ = try await application.discover(on: phase3Host())
        let attachmentsBeforeSelection = await transport.attachments()
        XCTAssertTrue(attachmentsBeforeSelection.isEmpty)

        let state = await application.selectPane(selectedPane.id)
        guard case let .attached(attachedSession, attachedPane) = state else {
            XCTFail("Selecting a pane should attach that pane")
            return
        }
        XCTAssertEqual(attachedSession, session)
        XCTAssertEqual(attachedPane, selectedPane)
        XCTAssertNotEqual(firstPane.id, selectedPane.id)

        let attachments = await transport.attachments()
        XCTAssertEqual(attachments, [selectedPane])
        let attachmentTargets = await transport.attachmentTargets()
        XCTAssertEqual(attachmentTargets, [selectedPane.id])
    }

    func testRestoreLastPaneAttachesOnlyWhenExplicitlyRequested() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let session = try recordedSession(in: fixture, id: "default")
        let lastPane = try XCTUnwrap(phase3Panes(in: session).last)
        let transport = Phase3TerminalTransport()
        let application = makePhase3Application(
            fixture: fixture,
            transport: transport,
            lastPaneID: lastPane.id
        )

        let stateAfterDiscovery = try await application.discover(on: phase3Host())
        guard case .panes = stateAfterDiscovery else {
            XCTFail("Restoration should start from the pane list")
            return
        }
        let attachmentsBeforeRestore = await transport.attachments()
        XCTAssertTrue(attachmentsBeforeRestore.isEmpty)

        let restoredState = await application.restoreLastPane()
        guard case let .attached(attachedSession, attachedPane) = restoredState else {
            XCTFail("Explicit restore should attach the remembered pane")
            return
        }
        XCTAssertEqual(attachedSession, session)
        XCTAssertEqual(attachedPane, lastPane)
        let attachments = await transport.attachments()
        XCTAssertEqual(attachments, [lastPane])
        let attachmentTargets = await transport.attachmentTargets()
        XCTAssertEqual(attachmentTargets, [lastPane.id])
    }

    func testMissingPaneReturnsToListWithPresentableExplanation() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let session = try recordedSession(in: fixture, id: "default")
        let pane = try recordedPane(in: session, id: "w55:p1")
        let transport = Phase3TerminalTransport(missingPaneIDs: [pane.id])
        let application = makePhase3Application(
            fixture: fixture,
            transport: transport
        )

        _ = try await application.discover(on: phase3Host())
        let stateAfterMissingAttach = await application.selectPane(pane.id)
        guard case let .panes(listedSession, message) = stateAfterMissingAttach else {
            XCTFail("A missing pane should return to the pane list")
            return
        }

        XCTAssertEqual(listedSession, session)
        XCTAssertFalse(message?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let attachments = await transport.attachments()
        XCTAssertEqual(attachments, [pane])
        let attachmentTargets = await transport.attachmentTargets()
        XCTAssertEqual(attachmentTargets, [pane.id])
    }
}

private func recordedSession(
    in fixture: Phase3HerdrFixture,
    id: HerdrSession.ID
) throws -> HerdrSession {
    try XCTUnwrap(fixture.sessions.first { $0.id == id })
}

private func recordedPane(
    in session: HerdrSession,
    id: Pane.ID
) throws -> Pane {
    try XCTUnwrap(phase3Panes(in: session).first { $0.id == id })
}
