import Foundation
import HerdrKit

/// Bridges the app's already-connected workflow into the shared Picker state
/// machine. The Picker owns navigation and refresh policy; the workflow keeps
/// the authenticated SSH/Mosh context and performs actual Herdr operations.
actor RootPanePickerDiscovery: HerdrDiscovering {
    let workflow: any HerdrWorkflowCoordinating
    private var didCompleteInitialDiscovery = false

    init(workflow: any HerdrWorkflowCoordinating) {
        self.workflow = workflow
    }

    func snapshot(for host: Host) async throws -> HerdrSnapshot {
        if didCompleteInitialDiscovery {
            return try await workflow.refreshSnapshot(on: host)
        }
        _ = try await workflow.discover(on: host)
        guard let snapshot = await workflow.currentSnapshot() else {
            throw RootPanePickerAdapterError.discoveryUnavailable
        }
        didCompleteInitialDiscovery = true
        return snapshot
    }
}

struct RootPanePickerTransport: TerminalTransport,
    HerdrSessionAwareTerminalTransport,
    HerdrPaneControlReleasing,
    HerdrPickerOrdinaryTerminalSelecting,
    Sendable
{
    let workflow: any HerdrWorkflowCoordinating
    let kind: ActiveTransport

    func connect(to _: Host) async throws {}

    func attach(to pane: Pane) async throws {
        let state = await workflow.selectPane(pane.id)
        try validate(state)
    }

    func attach(to pane: Pane, in session: HerdrSession) async throws {
        let state: HerdrBrowserState
        if let selector = workflow as? any HerdrSessionPaneSelecting {
            state = await selector.selectPane(
                pane.id,
                in: session.id
            )
        } else {
            state = await workflow.selectPane(pane.id)
        }
        try validate(state)
    }

    func releaseControl(for _: Pane.ID) async {
        await workflow.suspendAttachedControl()
    }

    func selectOrdinaryTerminal() async throws {
        guard let selector = workflow as? any HerdrExistingConnectionTerminalOpening else {
            throw RootPanePickerAdapterError.ordinaryTerminalUnavailable
        }
        let state = try await selector.openOrdinaryTerminalWithoutReconnect()
        guard case .ordinaryTerminal = state else {
            throw RootPanePickerAdapterError.ordinaryTerminalUnavailable
        }
    }

    func send(_: [UInt8]) async throws {
        throw RootPanePickerAdapterError.transportUnavailable
    }

    func resize(columns _: Int, rows _: Int) async throws {
        throw RootPanePickerAdapterError.transportUnavailable
    }

    func disconnect() async {}

    private func validate(_ state: HerdrBrowserState) throws {
        guard case .attached = state else {
            if case let .panes(_, message) = state,
               let message {
                throw RootPanePickerAdapterError.operationFailed(message)
            }
            throw RootPanePickerAdapterError.operationFailed(
                "The selected Herdr pane could not be attached."
            )
        }
    }
}

enum RootPanePickerAdapterError: Error, LocalizedError, Sendable {
    case discoveryUnavailable
    case operationFailed(String)
    case ordinaryTerminalUnavailable
    case transportUnavailable

    var errorDescription: String? {
        switch self {
        case .discoveryUnavailable:
            "Herdr discovery did not return a snapshot."
        case let .operationFailed(message):
            message
        case .ordinaryTerminalUnavailable:
            "The ordinary terminal is unavailable while this host is connected."
        case .transportUnavailable:
            "The connected terminal owns this transport."
        }
    }
}
