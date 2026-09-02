import Foundation
import HerdrKit
import XCTest
@testable import Mudi

final class Phase6PanePickerTests: XCTestCase {  // pi-lens-ignore: type_body_length
    func testPanePickerCompactPresentationUsesMediumLargeAndDragIndicator() {
        let policy = PanePickerPresentationPolicy.compactSheet

        XCTAssertEqual(policy.compactDetents, [.medium, .large])
        XCTAssertTrue(policy.showsDragIndicator)
    }

    func testPanePickerDismissalUsesNativeSystemInteraction() {
        // Outside taps at medium, swipe-down, and popover outside taps are
        // handled by the system sheet and flow through the presentation
        // Binding into dismissPanePicker(). Custom gesture bridges broke
        // detent dragging and must not return.
        XCTAssertTrue(
            PanePickerPresentationPolicy.compactSheet
                .usesSystemInteractiveDismissal
        )
    }

    func testIPadSheetUsesCenteredWidthCap() {
        // iPad presents the Picker as a bottom sheet (same model as
        // iPhone): centered with a content-capped width; height is driven
        // by the medium/large detents.
        let landscape = PanePickerPresentationPolicy.popoverContentWidth(
            for: 1180
        )
        XCTAssertEqual(landscape, 420)

        let portrait = PanePickerPresentationPolicy.popoverContentWidth(
            for: 820
        )
        XCTAssertEqual(portrait, 320)
    }

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

    func testPanePickerPresentationBuildsWorktreeTreeAndFlattensTabsWithoutExposingTabIDs() throws {
        let fixture = try Phase3HerdrFixtures.single()
        let snapshot = phase6Snapshot(from: fixture)
        let sections = panePickerPresentationSections(in: snapshot)

        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections.first?.title, "Herdr panes")
        let roots = try XCTUnwrap(sections.first?.roots)
        XCTAssertEqual(roots.map(\.title), ["mudiapp", "~"])
        let workspaceTree = try XCTUnwrap(roots.first)
        XCTAssertEqual(workspaceTree.children.map(\.title), ["phase6-pane-picker-impl"])
        XCTAssertFalse(workspaceTree.isLinkedWorktree)
        XCTAssertTrue(workspaceTree.children.first?.isLinkedWorktree == true)
        XCTAssertFalse(roots[1].isLinkedWorktree)
        XCTAssertEqual(workspaceTree.rows.map(\.paneID), ["w55:p1"])
        XCTAssertEqual(
            workspaceTree.children.flatMap(\.rows).map(\.paneID),
            ["w5R:p1", "w5R:p2"]
        )
        XCTAssertEqual(roots[1].rows.map(\.paneID), ["w56:p1"])
        XCTAssertEqual(
            sections.flatMap(\.rows).map(\.paneID),
            ["w55:p1", "w5R:p1", "w5R:p2", "w56:p1"],
            "Tree preorder must render each workspace before its linked-worktree descendants"
        )
        XCTAssertEqual(
            snapshot.sessions.first?.workspaces.first?.worktree?.repoName,
            "mudiapp"
        )
        XCTAssertNil(
            snapshot.sessions.first?.workspaces.first(where: { $0.name == "~" })?.worktree,
            "Workspaces without CLI worktree metadata remain standalone"
        )

        let tabIDs = snapshot.sessions
            .flatMap(\.workspaces)
            .flatMap(\.tabs)
            .map(\.id)
        let visibleText = sections.flatMap(\.visibleText)
        for tabID in tabIDs {
            XCTAssertFalse(
                visibleText.contains { $0.contains(tabID) },
                "Internal tab ID \(tabID) must not be user-visible"
            )
        }
    }

    func testPanePickerGroupsByRepoKeyEvenWhenWorkspaceLabelsAreUnrelated() throws {
        let fixture = try Phase3HerdrFixtures.single()
        var session = try XCTUnwrap(phase6Snapshot(from: fixture).sessions.first)
        let root = try XCTUnwrap(
            session.workspaces.first { $0.worktree?.isLinkedWorktree == false }
        )
        let linked = try XCTUnwrap(
            session.workspaces.first { $0.worktree?.isLinkedWorktree == true }
        )
        session.workspaces = session.workspaces.map { workspace in
            var renamed = workspace
            if workspace.id == root.id {
                renamed.name = "primary checkout"
            } else if workspace.id == linked.id {
                renamed.name = "review task"
            }
            return renamed
        }

        let sections = panePickerPresentationSections(
            in: HerdrSnapshot(sessions: [session])
        )
        let roots = try XCTUnwrap(sections.first?.roots)
        let repoRoot = try XCTUnwrap(roots.first { $0.id == root.id })

        XCTAssertEqual(repoRoot.children.map(\.id), [linked.id])
        XCTAssertEqual(repoRoot.children.map(\.title), ["review task"])
    }

    func testWorktreeMetadataDecodesAuthoritativeFieldsAndLegacyWorkspaceDefaultsToNil() throws {
        let metadataPayload = #"""
        {
          "checkout_path": "/Users/tony.liu/Developer/personal/mudiapp-phase6-pane-picker-impl",
          "is_linked_worktree": true,
          "repo_key": "/Users/tony.liu/Developer/personal/mudiapp/.git",
          "repo_name": "mudiapp",
          "repo_root": "/Users/tony.liu/Developer/personal/mudiapp"
        }
        """#
        let metadata = try JSONDecoder().decode(
            WorktreeMetadata.self,
            from: Data(metadataPayload.utf8)
        )
        XCTAssertEqual(
            metadata.checkoutPath,
            "/Users/tony.liu/Developer/personal/mudiapp-phase6-pane-picker-impl"
        )
        XCTAssertTrue(metadata.isLinkedWorktree)
        XCTAssertEqual(
            metadata.repoKey,
            "/Users/tony.liu/Developer/personal/mudiapp/.git"
        )
        XCTAssertEqual(metadata.repoName, "mudiapp")
        XCTAssertEqual(
            metadata.repoRoot,
            "/Users/tony.liu/Developer/personal/mudiapp"
        )

        let legacyPayload = #"""
        {
          "id": "legacy",
          "name": "legacy",
          "tabs": []
        }
        """#
        let workspace = try JSONDecoder().decode(
            Workspace.self,
            from: Data(legacyPayload.utf8)
        )

        XCTAssertNil(workspace.worktree)
    }

    func testPanePickerPresentationGroupsMultipleSessionsByHumanName() throws {
        let fixture = try Phase3HerdrFixtures.multiple()
        let snapshot = phase6Snapshot(from: fixture)
        let sections = panePickerPresentationSections(in: snapshot)

        XCTAssertEqual(
            sections.map(\.title),
            snapshot.sessions.map(\.name)
        )
        let defaultPresentation = try XCTUnwrap(
            sections.first { $0.id == snapshot.sessions[0].id }
        )
        let additionalPresentation = try XCTUnwrap(
            sections.first { $0.id == snapshot.sessions[1].id }
        )
        XCTAssertEqual(defaultPresentation.roots.map(\.id), ["w55", "w56"])
        XCTAssertEqual(
            defaultPresentation.roots.first?.children.map(\.id),
            ["w5R"]
        )
        XCTAssertEqual(
            defaultPresentation.rows.map(\.paneID),
            ["w55:p1", "w5R:p1", "w5R:p2", "w56:p1"]
        )
        XCTAssertEqual(additionalPresentation.roots.map(\.id), ["w1"])
        XCTAssertEqual(additionalPresentation.rows.map(\.paneID), ["w1:p1"])
        let tabIDs = snapshot.sessions
            .flatMap(\.workspaces)
            .flatMap(\.tabs)
            .map(\.id)
        let visibleText = sections.flatMap(\.visibleText)
        for tabID in tabIDs {
            XCTAssertFalse(
                visibleText.contains { $0.contains(tabID) },
                "Internal tab ID \(tabID) must not be user-visible"
            )
        }
    }

    func testPanePickerPresentationAddsWorkspaceContextOnlyForDuplicateNames() throws {
        let fixture = try Phase3HerdrFixtures.single()
        let snapshot = phase6Snapshot(from: fixture)
        let sections = panePickerPresentationSections(in: snapshot)
        let rows = sections.flatMap(\.rows)

        let duplicateAgentRows = rows.filter { $0.name == "pi" }
        XCTAssertGreaterThanOrEqual(duplicateAgentRows.count, 2)
        XCTAssertTrue(
            duplicateAgentRows.allSatisfy { $0.workspaceContext != nil },
            "Duplicate visible pane names should receive subtle workspace context"
        )
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

        let discoveryHostsBeforeDismissal = phase6DiscoveryHosts(
            in: operationsAfterManualRefresh
        )
        _ = await application.dismissPicker()
        let scheduledAfterDismissal = await scheduler.scheduledJobCount()
        XCTAssertEqual(scheduledAfterDismissal, 0)

        await scheduler.advance(by: 1)
        let operationsAfterDismissal = await recorder.operations()
        XCTAssertEqual(
            phase6DiscoveryHosts(in: operationsAfterDismissal),
            discoveryHostsBeforeDismissal,
            "A dismissed Picker must not continue scheduled discovery"
        )
        XCTAssertEqual(
            phase6Disconnects(in: operationsAfterDismissal),
            [.disconnect],
            "Dismissing a Host Picker must still disconnect the Host"
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
