import Foundation
import HerdrKit
import XCTest
@testable import Mudi

final class Phase6PanePickerTests: XCTestCase {
    func testSuccessfulHostConnectionPresentsPanePickerInsteadOfLegacyHerdrBrowser() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let application = makeMissingPhase6Application(
            snapshots: [phase6Snapshot(from: fixture)]
        )

        let state = try await application.connect(to: phase6Host())

        guard case .panePicker = state else {
            XCTFail(
                "A successful Host connection should present the Pane Picker, not the legacy Herdr browser state"
            )
            return
        }
    }

    func testPanePickerPreservesRecordedSessionWorkspacePaneAndAgentHierarchy() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let expected = phase6Snapshot(from: fixture)
        let application = makeMissingPhase6Application(snapshots: [expected])
        let host = phase6Host()

        _ = try await application.connect(to: host)
        let state = await application.openPicker(from: .host)

        guard case let .panePicker(picker) = state else {
            XCTFail("The Host picker should expose a pane snapshot")
            return
        }

        XCTAssertEqual(picker.host, host)
        XCTAssertEqual(picker.origin, .host)
        XCTAssertEqual(picker.snapshot.sessions.map(\.id), expected.sessions.map(\.id))

        for expectedSession in expected.sessions {
            let actualSession = try XCTUnwrap(
                picker.snapshot.sessions.first { $0.id == expectedSession.id }
            )
            XCTAssertEqual(actualSession.name, expectedSession.name)
            XCTAssertEqual(actualSession.isDefault, expectedSession.isDefault)

            for expectedWorkspace in expectedSession.workspaces {
                let actualWorkspace = try XCTUnwrap(
                    actualSession.workspaces.first { $0.id == expectedWorkspace.id }
                )
                XCTAssertEqual(actualWorkspace.name, expectedWorkspace.name)

                for expectedTab in expectedWorkspace.tabs {
                    let actualTab = try XCTUnwrap(
                        actualWorkspace.tabs.first { $0.id == expectedTab.id }
                    )
                    XCTAssertEqual(actualTab.name, expectedTab.name)

                    for expectedPane in expectedTab.panes {
                        let actualPane = try XCTUnwrap(
                            actualTab.panes.first { $0.id == expectedPane.id }
                        )
                        XCTAssertEqual(actualPane.title, expectedPane.title)
                        XCTAssertEqual(
                            actualPane.agent,
                            expectedPane.agent,
                            "Pane \(expectedPane.id) must keep its recorded agent name and status"
                        )
                    }
                }
            }
        }
    }

    func testVisiblePickerRefreshesFromLaterOfficialSnapshotByPaneIDAndStopsAfterDismissal() async throws {
        let initialFixture = try Phase3HerdrFixtures.single()
        let laterFixture = try Phase3HerdrFixtures.multiple()
        let initial = phase6Snapshot(from: initialFixture)
        let later = phase6Snapshot(from: laterFixture)
        let recorder = Phase6OperationRecorder()
        let scheduler = Phase6TestScheduler()
        let transport = Phase6PaneControlTransport(recorder: recorder)
        let application = makeMissingPhase6Application(
            snapshots: [initial, later],
            recorder: recorder,
            transport: transport,
            scheduler: scheduler
        )
        let host = phase6Host()

        _ = try await application.connect(to: host)
        _ = await application.openPicker(from: .host)

        let scheduledBeforeAdvance = await scheduler.scheduledJobCount()
        XCTAssertEqual(
            scheduledBeforeAdvance,
            1,
            "A visible Picker should own one deterministic refresh job"
        )

        await scheduler.advance(by: 1)
        let automaticState = await application.currentState()
        guard case let .panePicker(automaticPicker) = automaticState else {
            XCTFail("Refreshing a visible Picker should keep the Picker visible")
            return
        }
        XCTAssertEqual(
            automaticPicker.snapshot,
            later,
            "The scheduled refresh must apply the later official snapshot"
        )
        let expectedPanesByID = phase6PanesByID(in: later)
        let automaticPanesByID = phase6PanesByID(in: automaticPicker.snapshot)
        XCTAssertEqual(
            Set(automaticPanesByID.keys),
            Set(expectedPanesByID.keys)
        )
        for (paneID, expectedPane) in expectedPanesByID {
            let actualPane = try XCTUnwrap(automaticPanesByID[paneID])
            XCTAssertEqual(actualPane.title, expectedPane.title)
            XCTAssertEqual(
                actualPane.agent,
                expectedPane.agent,
                "Refresh must keep the status belonging to pane \(paneID)"
            )
        }

        let operationsAfterScheduledRefresh = await recorder.operations()
        XCTAssertEqual(
            phase6DiscoveryHosts(in: operationsAfterScheduledRefresh),
            [host, host],
            "Scheduled refresh must use the same discovery boundary as initial load"
        )

        let manualState = await application.refreshPicker()
        guard case let .panePicker(manualPicker) = manualState else {
            XCTFail("Manual refresh should keep the Picker visible")
            return
        }
        XCTAssertEqual(manualPicker.snapshot, later)

        let operationsAfterManualRefresh = await recorder.operations()
        XCTAssertEqual(
            phase6DiscoveryHosts(in: operationsAfterManualRefresh),
            [host, host, host],
            "Manual refresh must use the official discovery path too"
        )

        let operationCountBeforeDismissal = operationsAfterManualRefresh.count
        _ = await application.dismissPicker()
        let scheduledAfterDismissal = await scheduler.scheduledJobCount()
        XCTAssertEqual(scheduledAfterDismissal, 0)

        await scheduler.advance(by: 1)
        let operationsAfterDismissal = await recorder.operations()
        XCTAssertEqual(
            operationsAfterDismissal.count,
            operationCountBeforeDismissal,
            "A dismissed Picker must not continue scheduled discovery"
        )
    }

    func testDismissingUnselectedHostPickerDisconnectsTheHost() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let recorder = Phase6OperationRecorder()
        let transport = Phase6PaneControlTransport(recorder: recorder)
        let application = makeMissingPhase6Application(
            snapshots: [phase6Snapshot(from: fixture)],
            recorder: recorder,
            transport: transport
        )
        let host = phase6Host()

        _ = try await application.connect(to: host)
        _ = await application.openPicker(from: .host)
        let state = await application.dismissPicker()

        guard case let .hosts(hosts) = state else {
            XCTFail("Dismissing an unselected Host Picker should return to Hosts")
            return
        }
        XCTAssertEqual(hosts, [host])

        let connectedAfterDismissal = await transport.isConnected()
        XCTAssertFalse(connectedAfterDismissal)
        let operations = await recorder.operations()
        XCTAssertEqual(
            phase6Disconnects(in: operations),
            [.disconnect],
            "Cancelling a Host-origin Picker must disconnect its Host"
        )
    }

    func testDismissingTerminalPickerKeepsTheAttachedPaneAndHostContext() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let snapshot = phase6Snapshot(from: fixture)
        let session = try XCTUnwrap(snapshot.sessions.first)
        let pane = try XCTUnwrap(phase6Panes(in: snapshot).first)
        let recorder = Phase6OperationRecorder()
        let transport = Phase6PaneControlTransport(recorder: recorder)
        let application = makeMissingPhase6Application(
            snapshots: [snapshot],
            recorder: recorder,
            transport: transport
        )
        let host = phase6Host()

        _ = try await application.connect(to: host)
        _ = await application.openPicker(from: .host)
        let attachedState = await application.selectPane(pane.id)
        guard case let .terminal(.attached(attached)) = attachedState else {
            XCTFail("Selecting the current pane should produce an attached terminal")
            return
        }
        XCTAssertEqual(attached.pane.id, pane.id)

        let pickerState = await application.openPicker(from: .terminal)
        guard case let .panePicker(picker) = pickerState else {
            XCTFail("The terminal should open the shared Pane Picker")
            return
        }
        XCTAssertEqual(picker.attachedTerminal?.pane.id, pane.id)

        let dismissedState = await application.dismissPicker()
        guard case let .terminal(.attached(restored)) = dismissedState else {
            XCTFail("Dismissing a terminal-origin Picker should restore the attached terminal")
            return
        }
        XCTAssertEqual(restored.host, host)
        XCTAssertEqual(restored.session.id, session.id)
        XCTAssertEqual(restored.pane.id, pane.id)

        let operations = await recorder.operations()
        XCTAssertTrue(
            phase6Disconnects(in: operations).isEmpty,
            "Closing a terminal-origin Picker must not disconnect the Host"
        )
    }

    func testSwitchingAttachedPaneReleasesOldControlBeforeTakingOverNewPaneWithoutReconnect() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let snapshot = phase6Snapshot(from: fixture)
        let session = try XCTUnwrap(snapshot.sessions.first)
        let panes = phase6Panes(in: snapshot)
        let oldPane = try XCTUnwrap(panes.first)
        let newPane = try XCTUnwrap(panes.dropFirst().first)
        let recorder = Phase6OperationRecorder()
        let transport = Phase6PaneControlTransport(recorder: recorder)
        let application = makeMissingPhase6Application(
            snapshots: [snapshot],
            recorder: recorder,
            transport: transport
        )
        let host = phase6Host()

        _ = try await application.connect(to: host)
        _ = await application.openPicker(from: .host)
        _ = await application.selectPane(oldPane.id)
        _ = await application.openPicker(from: .terminal)

        let switchedState = await application.selectPane(newPane.id)
        guard case let .terminal(.attached(switched)) = switchedState else {
            XCTFail("Selecting another pane should leave the terminal attached")
            return
        }
        XCTAssertEqual(switched.host, host)
        XCTAssertEqual(switched.session.id, session.id)
        XCTAssertEqual(switched.pane.id, newPane.id)

        let operations = await recorder.operations()
        XCTAssertEqual(
            phase6ControlOperations(in: operations),
            [
                .takeover(sessionID: session.id, paneID: oldPane.id),
                .releaseControl(oldPane.id),
                .takeover(sessionID: session.id, paneID: newPane.id)
            ]
        )
        XCTAssertEqual(phase6Connections(in: operations), [host])
    }

    func testSelectingOrdinaryTerminalDoesNotAttachAnyPane() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let snapshot = phase6Snapshot(from: fixture)
        let recorder = Phase6OperationRecorder()
        let transport = Phase6PaneControlTransport(recorder: recorder)
        let application = makeMissingPhase6Application(
            snapshots: [snapshot],
            recorder: recorder,
            transport: transport
        )
        let host = phase6Host()

        _ = try await application.connect(to: host)
        _ = await application.openPicker(from: .host)
        let state = await application.selectOrdinaryTerminal()

        guard case let .terminal(.ordinary(ordinary)) = state else {
            XCTFail("The ordinary terminal must remain distinct from pane attach")
            return
        }
        XCTAssertEqual(ordinary, host)

        let operations = await recorder.operations()
        XCTAssertTrue(
            phase6ControlOperations(in: operations).isEmpty,
            "Selecting ordinary terminal must not release or take over a Herdr pane"
        )
    }

    private func phase6PanesByID(in snapshot: HerdrSnapshot) -> [Pane.ID: Pane] {
        Dictionary(
            uniqueKeysWithValues: phase6Panes(in: snapshot).map { ($0.id, $0) }
        )
    }

    private func phase6DiscoveryHosts(in operations: [Phase6Operation]) -> [Host] {
        operations.compactMap { operation in
            guard case let .discover(host) = operation else { return nil }
            return host
        }
    }

    private func phase6Connections(in operations: [Phase6Operation]) -> [Host] {
        operations.compactMap { operation in
            guard case let .connect(host) = operation else { return nil }
            return host
        }
    }

    private func phase6Disconnects(in operations: [Phase6Operation]) -> [Phase6Operation] {
        operations.filter { operation in
            if case .disconnect = operation { return true }
            return false
        }
    }

    private func phase6ControlOperations(in operations: [Phase6Operation]) -> [Phase6Operation] {
        operations.filter { operation in
            switch operation {
            case .releaseControl, .takeover:
                return true
            case .connect, .discover, .disconnect:
                return false
            }
        }
    }
}
