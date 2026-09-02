import Foundation
import HerdrKit
import XCTest
@testable import Mudi

final class Phase6WorkspaceCreationTests: XCTestCase {
    func testWorkspaceCreateUsesOfficialNoFocusCommandAndDecodesRootPane() async throws {
        let channel = Phase6WorkspaceCreateCommandChannel(
            response: capturedWorkspaceCreateResponse
        )
        let session = SSHShellSession(connectedChannel: channel)
        let discovery = SSHHerdrDiscovery(session: session)

        let creation = try await discovery.createWorkspace()

        XCTAssertEqual(creation.workspaceID, "w5S")
        XCTAssertEqual(creation.tabID, "w5S:t1")
        XCTAssertEqual(creation.rootPaneID, "w5S:p1")
        let commands = await channel.commands()
        XCTAssertEqual(
            commands,
            [SSHLoginShellCommand.wrap("herdr workspace create --no-focus")]
        )
    }

    @MainActor
    func testCreateWorkspaceRefreshesAndTakesOverReturnedRootPane() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let creation = capturedWorkspaceCreation()
        let refreshedSnapshot = snapshot(
            from: fixture,
            containing: creation
        )
        let recorder = Phase6WorkspaceCreationRecorder()
        let application = makePhase4NavigationApplication(
            fixture: fixture,
            workspaceCreation: creation,
            workspaceSnapshotAfterCreation: refreshedSnapshot,
            workspaceCreationRecorder: recorder
        )
        let host = phase4Host()
        try await application.save(host)
        application.model.connect(to: host)
        let pickerPresented = await waitForRootWorkspaceCondition {
            application.model.isPanePickerPresented
                && application.model.connectionState == .connected
        }
        XCTAssertTrue(pickerPresented)

        application.model.createWorkspaceFromPicker()

        let attached = await waitForRootWorkspaceCondition {
            guard case let .attached(_, pane) = application.model.herdrState else {
                return false
            }
            return pane.id == creation.rootPaneID
                && !application.model.isPanePickerPresented
        }
        XCTAssertTrue(attached)
        XCTAssertFalse(application.model.isCreatingWorkspace)
        let createCallCount = await recorder.callCount()
        XCTAssertEqual(createCallCount, 1)
        let attachments = await application.transport.attachments()
        XCTAssertEqual(attachments.last?.id ?? "", creation.rootPaneID)
    }

    @MainActor
    func testCreateWorkspaceFailureKeepsPickerUsableAndReentrantTapsAreIgnored() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let creation = capturedWorkspaceCreation()
        let recorder = Phase6WorkspaceCreationRecorder()
        let gate = Phase2ConnectionGate()
        let application = makePhase4NavigationApplication(
            fixture: fixture,
            workspaceCreation: creation,
            workspaceCreationShouldFail: true,
            workspaceCreationGate: gate,
            workspaceCreationRecorder: recorder
        )
        let host = phase4Host()
        try await application.save(host)
        application.model.connect(to: host)
        let pickerPresented = await waitForRootWorkspaceCondition {
            application.model.isPanePickerPresented
                && application.model.connectionState == .connected
        }
        XCTAssertTrue(pickerPresented)

        application.model.createWorkspaceFromPicker()
        await gate.waitUntilStarted()
        application.model.createWorkspaceFromPicker()
        let createCallCount = await recorder.callCount()
        XCTAssertEqual(createCallCount, 1)
        await gate.release()

        let failed = await waitForRootWorkspaceCondition {
            application.model.isPanePickerPresented
                && application.model.panePicker?.message != nil
                && !application.model.isCreatingWorkspace
        }
        XCTAssertTrue(failed)
        XCTAssertEqual(application.model.panePicker?.origin, .host)
        let attachments = await application.transport.attachments()
        XCTAssertTrue(attachments.isEmpty)
    }

    @MainActor
    private func waitForRootWorkspaceCondition(
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

private actor Phase6WorkspaceCreateCommandChannel: PTYChannel,
    SSHCommandExecutingChannel
{
    private let response: [UInt8]
    private var recordedCommands: [String] = []

    init(response: String) {
        self.response = Array(response.utf8)
    }

    func execute(_ command: String) async throws -> [UInt8] {
        recordedCommands.append(command)
        return response
    }

    func send(_: [UInt8]) async throws {}

    func resize(columns _: Int, rows _: Int) async throws {}

    func close() async {}

    func commands() -> [String] {
        recordedCommands
    }
}

actor Phase6WorkspaceCreationRecorder {
    private var calls = 0

    func record() {
        calls += 1
    }

    func callCount() -> Int {
        calls
    }
}

enum Phase6WorkspaceCreationError: Error, LocalizedError, Sendable {
    case failed
    case unavailable

    var errorDescription: String? {
        switch self {
        case .failed:
            "The Herdr workspace could not be created."
        case .unavailable:
            "Workspace creation is unavailable in this test boundary."
        }
    }
}

private func capturedWorkspaceCreation() -> HerdrWorkspaceCreation {
    HerdrWorkspaceCreation(
        workspaceID: "w5S",
        tabID: "w5S:t1",
        rootPaneID: "w5S:p1"
    )
}

private func snapshot(
    from fixture: Phase3HerdrFixture,
    containing creation: HerdrWorkspaceCreation
) -> HerdrSnapshot {
    var snapshot = phase6Snapshot(from: fixture)
    guard var session = snapshot.sessions.first else { return snapshot }
    session.workspaces.append(
        Workspace(
            id: creation.workspaceID,
            name: "mudiapp",
            tabs: [
                Tab(
                    id: creation.tabID,
                    name: creation.tabID,
                    panes: [Pane(id: creation.rootPaneID, title: creation.rootPaneID)]
                )
            ]
        )
    )
    snapshot.sessions[0] = session
    return snapshot
}

/// Captured from `herdr workspace create --no-focus` on Herdr 0.8.2 in the
/// assigned Herdr session. The temporary workspace `w5S` was closed
/// immediately after capture; its IDs are retained only for protocol tests.
private let capturedWorkspaceCreateResponse = #"""
{
  "id": "cli:workspace:create",
  "result": {
    "root_pane": {
      "agent_status": "unknown",
      "cwd": "/Users/tony.liu/Developer/personal/mudiapp",
      "focused": false,
      "foreground_cwd": "/Users/tony.liu/Developer/personal/mudiapp",
      "pane_id": "w5S:p1",
      "revision": 0,
      "scroll": {
        "max_offset_from_bottom": 0,
        "offset_from_bottom": 0,
        "viewport_rows": 68
      },
      "tab_id": "w5S:t1",
      "terminal_id": "term_65a5b46fec1c72a",
      "workspace_id": "w5S"
    },
    "tab": {
      "agent_status": "unknown",
      "focused": false,
      "label": "1",
      "number": 1,
      "pane_count": 1,
      "tab_id": "w5S:t1",
      "workspace_id": "w5S"
    },
    "type": "workspace_created",
    "workspace": {
      "active_tab_id": "w5S:t1",
      "agent_status": "unknown",
      "focused": false,
      "label": "mudiapp",
      "number": 3,
      "pane_count": 1,
      "tab_count": 1,
      "workspace_id": "w5S"
    }
  }
}
"""#
