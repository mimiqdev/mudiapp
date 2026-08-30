import Foundation
import HerdrKit
import XCTest
@testable import Mudi

final class Phase3HerdrWorkflowTests: XCTestCase {
    func testEmptySnapshotOffersOrdinarySSHPathWithoutPaneAttach() async throws {
        let host = phase3Host()
        let transport = Phase3TerminalTransport()
        let application = makeMissingPhase3Application(
            snapshot: HerdrSnapshot(sessions: []),
            transport: transport
        )

        let browserState = try await application.discover(on: host)
        guard case .empty = browserState else {
            XCTFail("An empty Herdr snapshot should show the empty state")
            return
        }

        let discoveryRequests = await application.discovery.requests()
        XCTAssertEqual(discoveryRequests, [host])
        let attachmentsBeforeTerminal = await transport.attachments()
        XCTAssertTrue(attachmentsBeforeTerminal.isEmpty)

        let terminalState = try await application.openOrdinaryTerminal()
        guard case .ordinaryTerminal = terminalState else {
            XCTFail("An empty Herdr snapshot should offer the ordinary SSH terminal")
            return
        }

        let connections = await transport.connections()
        XCTAssertEqual(connections, [host])
        let attachmentsAfterTerminal = await transport.attachments()
        XCTAssertTrue(attachmentsAfterTerminal.isEmpty)
    }

    func testSingleSessionSkipsSessionPickerAndListsPanesAndAgents() async throws {
        let agentPane = phase3Pane(
            id: "pane-agent",
            title: "coding",
            agentName: "Pi",
            agentState: .working
        )
        let shellPane = phase3Pane(id: "pane-shell", title: "shell")
        let session = phase3Session(
            id: "default",
            name: "Default",
            panes: [agentPane, shellPane],
            isDefault: true
        )
        let application = makeMissingPhase3Application(
            snapshot: HerdrSnapshot(sessions: [session])
        )

        let browserState = try await application.discover(on: phase3Host())
        guard case let .panes(listedSession, message) = browserState else {
            XCTFail("One Herdr session should open its pane list without a session picker")
            return
        }

        XCTAssertNil(message)
        XCTAssertEqual(listedSession, session)
        XCTAssertEqual(phase3Panes(in: listedSession), [agentPane, shellPane])
        XCTAssertEqual(phase3Panes(in: listedSession).first?.agent, agentPane.agent)
    }

    func testMultipleSessionsListsSessionsBeforeShowingAnySessionPanes() async throws {
        let firstPane = phase3Pane(
            id: "first-pane",
            title: "first-task",
            agentName: "Pi",
            agentState: .waitingForInput
        )
        let secondPane = phase3Pane(
            id: "second-pane",
            title: "second-task",
            agentName: "Reviewer",
            agentState: .working
        )
        let firstSession = phase3Session(
            id: "first",
            name: "First session",
            panes: [firstPane]
        )
        let secondSession = phase3Session(
            id: "second",
            name: "Second session",
            panes: [secondPane]
        )
        let application = makeMissingPhase3Application(
            snapshot: HerdrSnapshot(sessions: [firstSession, secondSession])
        )

        let initialState = try await application.discover(on: phase3Host())
        guard case let .sessions(summaries) = initialState else {
            XCTFail("Multiple Herdr sessions should show a session list first")
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
        XCTAssertEqual(phase3Panes(in: listedSession), [firstPane])
        XCTAssertFalse(phase3Panes(in: listedSession).contains(secondPane))
    }

    func testListingPanesDoesNotAutomaticallyAttachOne() async throws {
        let pane = phase3Pane(
            id: "listed-pane",
            title: "existing-task",
            agentName: "Pi",
            agentState: .idle
        )
        let session = phase3Session(id: "session", name: "Session", panes: [pane])
        let transport = Phase3TerminalTransport()
        let application = makeMissingPhase3Application(
            snapshot: HerdrSnapshot(sessions: [session]),
            transport: transport
        )

        let state = try await application.discover(on: phase3Host())
        guard case .panes = state else {
            XCTFail("The single-session discovery should list panes")
            return
        }

        let attachments = await transport.attachments()
        XCTAssertTrue(attachments.isEmpty)
    }

    func testSelectingPaneAttachesOnlyAfterUserSelectsThatPane() async throws {
        let firstPane = phase3Pane(id: "first", title: "first")
        let selectedPane = phase3Pane(
            id: "selected",
            title: "selected-task",
            agentName: "Pi",
            agentState: .working
        )
        let session = phase3Session(
            id: "session",
            name: "Session",
            panes: [firstPane, selectedPane]
        )
        let transport = Phase3TerminalTransport()
        let application = makeMissingPhase3Application(
            snapshot: HerdrSnapshot(sessions: [session]),
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

        let attachments = await transport.attachments()
        XCTAssertEqual(attachments, [selectedPane])
    }

    func testRestoreLastPaneAttachesOnlyWhenExplicitlyRequested() async throws {
        let firstPane = phase3Pane(id: "first", title: "first")
        let lastPane = phase3Pane(
            id: "last",
            title: "last-task",
            agentName: "Pi",
            agentState: .waitingForInput
        )
        let session = phase3Session(
            id: "session",
            name: "Session",
            panes: [firstPane, lastPane]
        )
        let transport = Phase3TerminalTransport()
        let application = makeMissingPhase3Application(
            snapshot: HerdrSnapshot(sessions: [session]),
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
    }

    func testMissingPaneReturnsToListWithPresentableExplanation() async throws {
        let pane = phase3Pane(id: "gone", title: "finished-task")
        let session = phase3Session(id: "session", name: "Session", panes: [pane])
        let transport = Phase3TerminalTransport(missingPaneIDs: [pane.id])
        let application = makeMissingPhase3Application(
            snapshot: HerdrSnapshot(sessions: [session]),
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
    }
}
