import Foundation
import HerdrKit

/// The source of a Pane Picker presentation. A Host presentation owns the
/// connection until it is dismissed; a terminal presentation only changes the
/// selected control pane.
enum PanePickerOrigin: Equatable, Sendable {
    case host
    case terminal
}

/// The terminal context that is restored when a terminal-origin picker closes.
struct PanePickerAttachedTerminal: Equatable, Sendable {
    let host: Host
    let session: HerdrSession
    let pane: Pane
}

enum PanePickerTerminalContext: Equatable, Sendable {
    case ordinary(host: Host)
    case attached(PanePickerAttachedTerminal)
}

/// The complete, official Herdr projection rendered by the picker. Keeping
/// the original snapshot intact means pane identity remains the only join key
/// for agent information when discovery refreshes.
struct PanePickerState: Equatable, Sendable {
    let host: Host
    let origin: PanePickerOrigin
    var snapshot: HerdrSnapshot
    var attachedTerminal: PanePickerAttachedTerminal?
    var message: String?
    var isLoading: Bool

    init(
        host: Host,
        origin: PanePickerOrigin,
        snapshot: HerdrSnapshot,
        attachedTerminal: PanePickerAttachedTerminal? = nil,
        message: String? = nil,
        isLoading: Bool = false
    ) {
        self.host = host
        self.origin = origin
        self.snapshot = snapshot
        self.attachedTerminal = attachedTerminal
        self.message = message
        self.isLoading = isLoading
    }
}

enum PanePickerNavigationState: Equatable, Sendable {
    case hosts([Host])
    case legacyHerdrBrowser(HerdrBrowserState)
    case panePicker(PanePickerState)
    case terminal(PanePickerTerminalContext)
}

/// The state-machine boundary used by both the standalone contract tests and
/// the app's RootViewModel. Keeping this protocol small prevents a second UI
/// implementation from drifting on refresh, dismissal, or takeover policy.
protocol PanePickerCoordinating: Sendable {
    func connect(to host: Host) async throws -> PanePickerNavigationState
    func openPicker(from origin: PanePickerOrigin) async -> PanePickerNavigationState
    func synchronizeTerminalContext(_ context: PanePickerTerminalContext) async
    func refreshPicker() async -> PanePickerNavigationState
    func dismissPicker() async -> PanePickerNavigationState
    func selectPane(_ paneID: Pane.ID) async -> PanePickerNavigationState
    func selectOrdinaryTerminal() async -> PanePickerNavigationState
    func stopRefresh() async
    func restartRefresh() async
    func invalidateRefreshImmediately()
}

/// A synchronous cancellation token closes the window between a view leaving
/// the picker and its actor-backed scheduler cancellation being awaited.
private final class PanePickerRefreshCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true

    func activate() {
        lock.lock()
        active = true
        lock.unlock()
    }

    func invalidate() {
        lock.lock()
        active = false
        lock.unlock()
    }

    func isActive() -> Bool {
        lock.lock()
        let result = active
        lock.unlock()
        return result
    }
}

/// A connected-shell adapter can make ordinary-terminal selection part of the
/// same picker transaction without opening another host connection.
protocol HerdrPickerOrdinaryTerminalSelecting: Sendable {
    func selectOrdinaryTerminal() async throws
}

func refreshedPanePickerAttachment(
    _ attachedTerminal: PanePickerAttachedTerminal?,
    in snapshot: HerdrSnapshot
) -> PanePickerAttachedTerminal? {
    guard let attachedTerminal else { return nil }
    guard let session = snapshot.sessions.first(where: {
        $0.id == attachedTerminal.session.id
    }),
          let pane = session.workspaces
              .flatMap({ $0.tabs })
              .flatMap({ $0.panes })
              .first(where: { $0.id == attachedTerminal.pane.id })
    else {
        return attachedTerminal
    }
    return PanePickerAttachedTerminal(
        host: attachedTerminal.host,
        session: session,
        pane: pane
    )
}

func panePickerPresentableMessage(for error: Error) -> String {
    if let localizedError = error as? LocalizedError,
       let description = localizedError.errorDescription,
       !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return description
    }
    let description = error.localizedDescription
    return description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? "The requested operation failed."
        : description
}

func panePickerLocation(
    in snapshot: HerdrSnapshot,
    paneID: Pane.ID
) -> (session: HerdrSession, pane: Pane)? {
    for session in snapshot.sessions {
        for workspace in session.workspaces {
            for tab in workspace.tabs {
                if let pane = tab.panes.first(where: { $0.id == paneID }) {
                    return (session, pane)
                }
            }
        }
    }
    return nil
}

/// A separate release boundary makes the ordering of an attached-pane switch
/// explicit. A transport may implement this with the official
/// `terminal.release` frame or by closing its current control session.
protocol HerdrPaneControlReleasing: Sendable {
    func releaseControl(for paneID: Pane.ID) async
}

/// Refresh scheduling is injected so tests can drive refreshes with a virtual
/// clock. The live scheduler below is the only implementation that sleeps.
protocol PanePickerRefreshScheduling: Sendable {
    func schedule(
        every interval: Int,
        _ work: @escaping @Sendable () async -> Void
    ) async -> UUID
    func cancel(_ id: UUID) async
}

/// Type erasure lets RootViewModel inject a virtual scheduler in tests while
/// the shared state machine still has one concrete generic scheduler type.
struct AnyPanePickerRefreshScheduler: PanePickerRefreshScheduling, Sendable {
    private let base: any PanePickerRefreshScheduling

    init(_ base: any PanePickerRefreshScheduling) {
        self.base = base
    }

    func schedule(
        every interval: Int,
        _ work: @escaping @Sendable () async -> Void
    ) async -> UUID {
        await base.schedule(every: interval, work)
    }

    func cancel(_ id: UUID) async {
        await base.cancel(id)
    }
}

/// Wall-clock refreshes for the app UI. The scheduled work is awaited before
/// the next interval, and the picker coordinator also guards against a manual
/// refresh entering at the same time.
actor LivePanePickerRefreshScheduler: PanePickerRefreshScheduling {
    private var jobs: [UUID: Task<Void, Never>] = [:]

    func schedule(
        every interval: Int,
        _ work: @escaping @Sendable () async -> Void
    ) async -> UUID {
        let id = UUID()
        let nanoseconds = UInt64(max(1, interval)) * 1_000_000_000
        let task = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: nanoseconds)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await work()
            }
            await self?.remove(id)
        }
        jobs[id] = task
        return id
    }

    func cancel(_ id: UUID) async {
        jobs.removeValue(forKey: id)?.cancel()
    }

    private func remove(_ id: UUID) {
        jobs[id] = nil
    }
}

/// Coordinates the reusable pane-picker state independently from SwiftUI.
/// It is also the deterministic application boundary used by the Phase 6
/// tests: host connection, official discovery, refresh, dismissal, and pane
/// control all remain observable without a view or wall-clock task.
actor HerdrPanePickerCoordinator<
    Discovery: HerdrDiscovering,
    Transport: TerminalTransport,
    Scheduler: PanePickerRefreshScheduling
>: Sendable {
    let discovery: Discovery
    let transport: Transport
    let scheduler: Scheduler

    private var connectedHost: Host?
    private var latestSnapshot = HerdrSnapshot(sessions: [])
    private var navigationState: PanePickerNavigationState = .hosts([])
    private var scheduledRefreshID: UUID?
    private var refreshGeneration = UUID()
    private var refreshInFlight = false
    private var refreshWaiters: [CheckedContinuation<Void, Never>] = []
    nonisolated private let refreshCancellation = PanePickerRefreshCancellation()

    init(
        discovery: Discovery,
        transport: Transport,
        scheduler: Scheduler
    ) {
        self.discovery = discovery
        self.transport = transport
        self.scheduler = scheduler
    }

    /// Establishes the transport boundary and performs the first official
    /// discovery. Discovery failures stay inside the picker as an empty/error
    /// state; transport failures still propagate to the caller.
    func connect(to host: Host) async throws -> PanePickerNavigationState {
        await cancelRefresh()
        connectedHost = host
        do {
            try await transport.connect(to: host)
        } catch {
            connectedHost = nil
            navigationState = .hosts([])
            throw error
        }

        let result: (snapshot: HerdrSnapshot, message: String?)
        do {
            result = (try await discovery.snapshot(for: host), nil)
        } catch {
            result = (
                HerdrSnapshot(sessions: []),
                panePickerPresentableMessage(for: error)
            )
        }
        latestSnapshot = result.snapshot
        navigationState = .panePicker(
            PanePickerState(
                host: host,
                origin: .host,
                snapshot: result.snapshot,
                message: result.message
            )
        )
        await startRefresh()
        return navigationState
    }

    /// Presents the same picker from either a connected Host screen or a
    /// terminal toolbar. Opening it does not reconnect or rediscover; the
    /// currently held official snapshot is shown immediately and refreshes
    /// then use the same discovery boundary as the manual button.
    func synchronizeTerminalContext(_ context: PanePickerTerminalContext) {
        guard connectedHost != nil else { return }
        navigationState = .terminal(context)
    }

    func openPicker(from origin: PanePickerOrigin) async -> PanePickerNavigationState {
        await cancelRefresh()
        guard let host = connectedHost else {
            navigationState = .hosts([])
            return navigationState
        }

        let attachedTerminal: PanePickerAttachedTerminal?
        switch navigationState {
        case let .terminal(.attached(attached)) where origin == .terminal:
            attachedTerminal = attached
        default:
            attachedTerminal = nil
        }

        let message: String?
        if case let .panePicker(existing) = navigationState {
            message = existing.message
        } else {
            message = nil
        }
        navigationState = .panePicker(
            PanePickerState(
                host: host,
                origin: origin,
                snapshot: latestSnapshot,
                attachedTerminal: attachedTerminal,
                message: message
            )
        )
        await startRefresh()
        return navigationState
    }

    /// Manual and scheduled refreshes share this method. The actor flag is
    /// necessary because an actor can still be re-entered while discovery is
    /// suspended on network I/O.
    func refreshPicker() async -> PanePickerNavigationState {
        await refreshPicker(generation: nil)
    }

    func dismissPicker() async -> PanePickerNavigationState {
        guard case let .panePicker(picker) = navigationState else {
            return navigationState
        }
        await cancelRefresh()

        switch picker.origin {
        case .host:
            await transport.disconnect()
            connectedHost = nil
            latestSnapshot = HerdrSnapshot(sessions: [])
            navigationState = .hosts([picker.host])
        case .terminal:
            if let attachedTerminal = picker.attachedTerminal {
                navigationState = .terminal(.attached(attachedTerminal))
            } else {
                navigationState = .terminal(.ordinary(host: picker.host))
            }
        }
        return navigationState
    }

    func selectPane(_ paneID: Pane.ID) async -> PanePickerNavigationState {
        guard case let .panePicker(picker) = navigationState,
              let location = panePickerLocation(in: picker.snapshot, paneID: paneID)
        else {
            return navigationState
        }

        await cancelRefresh()
        if let attachedTerminal = picker.attachedTerminal {
            if attachedTerminal.pane.id == location.pane.id {
                navigationState = .terminal(.attached(attachedTerminal))
                return navigationState
            }
            if let releaser = transport as? any HerdrPaneControlReleasing {
                await releaser.releaseControl(for: attachedTerminal.pane.id)
            } else if let provider = transport as? any HerdrTerminalSessionProviding {
                await provider.releaseTerminalSession()
            }
        }

        do {
            try await attachPane(location.pane, in: location.session)
            navigationState = .terminal(
                .attached(
                    PanePickerAttachedTerminal(
                        host: picker.host,
                        session: location.session,
                        pane: location.pane
                    )
                )
            )
        } catch {
            navigationState = .panePicker(
                await pickerStateAfterFailure(picker, error: error)
            )
            await startRefresh()
        }
        return navigationState
    }

    func selectOrdinaryTerminal() async -> PanePickerNavigationState {
        guard case let .panePicker(picker) = navigationState else {
            return navigationState
        }
        await cancelRefresh()
        if let attachedTerminal = picker.attachedTerminal {
            if let releaser = transport as? any HerdrPaneControlReleasing {
                await releaser.releaseControl(for: attachedTerminal.pane.id)
            } else if let provider = transport as? any HerdrTerminalSessionProviding {
                await provider.releaseTerminalSession()
            }
        }
        do {
            if let selector = transport as? any HerdrPickerOrdinaryTerminalSelecting {
                try await selector.selectOrdinaryTerminal()
            }
            navigationState = .terminal(.ordinary(host: picker.host))
        } catch {
            navigationState = .panePicker(
                await pickerStateAfterFailure(picker, error: error)
            )
            await startRefresh()
        }
        return navigationState
    }

    func currentState() -> PanePickerNavigationState {
        navigationState
    }

    func stopRefresh() async {
        await cancelRefresh()
    }

    func restartRefresh() async {
        await cancelRefresh()
        await startRefresh()
    }

    nonisolated func invalidateRefreshImmediately() {
        refreshCancellation.invalidate()
    }

    private func attachPane(_ pane: Pane, in session: HerdrSession) async throws {
        if let sessionAwareTransport = transport as? any HerdrSessionAwareTerminalTransport {
            try await sessionAwareTransport.attach(to: pane, in: session)
        } else {
            try await transport.attach(to: pane)
        }
    }

    private func restore(_ attachedTerminal: PanePickerAttachedTerminal) async -> Bool {
        do {
            try await attachPane(attachedTerminal.pane, in: attachedTerminal.session)
            return true
        } catch {
            return false
        }
    }

    private func pickerStateAfterFailure(
        _ picker: PanePickerState,
        error: Error
    ) async -> PanePickerState {
        let restoredAttachment: PanePickerAttachedTerminal?
        if let attachedTerminal = picker.attachedTerminal,
           await restore(attachedTerminal) {
            restoredAttachment = attachedTerminal
        } else {
            restoredAttachment = nil
        }
        return PanePickerState(
            host: picker.host,
            origin: picker.origin,
            snapshot: picker.snapshot,
            attachedTerminal: restoredAttachment,
            message: panePickerPresentableMessage(for: error)
        )
    }

    private func startRefresh() async {
        let generation = UUID()
        refreshGeneration = generation
        refreshCancellation.activate()
        let scheduler = self.scheduler
        let cancellation = refreshCancellation
        let id = await scheduler.schedule(every: 1) { [weak self, cancellation] in
            guard cancellation.isActive() else { return }
            _ = await self?.refreshPicker(generation: generation)
        }
        guard case .panePicker = navigationState,
              generation == refreshGeneration
        else {
            await scheduler.cancel(id)
            return
        }
        scheduledRefreshID = id
    }

    private func cancelRefresh() async {
        refreshGeneration = UUID()
        refreshCancellation.invalidate()
        if let scheduledRefreshID {
            await scheduler.cancel(scheduledRefreshID)
            self.scheduledRefreshID = nil
        }
        guard refreshInFlight else { return }
        await withCheckedContinuation { continuation in
            if refreshInFlight {
                refreshWaiters.append(continuation)
            } else {
                continuation.resume()
            }
        }
    }

    private func finishRefresh() {
        refreshInFlight = false
        let waiters = refreshWaiters
        refreshWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func refreshPicker(generation: UUID?) async -> PanePickerNavigationState {
        guard case .panePicker = navigationState,
              let host = connectedHost
        else {
            return navigationState
        }
        if let generation, generation != refreshGeneration {
            return navigationState
        }
        guard !refreshInFlight, refreshCancellation.isActive() else {
            return navigationState
        }

        refreshInFlight = true
        defer { finishRefresh() }

        do {
            let snapshot = try await discovery.snapshot(for: host)
            guard case let .panePicker(picker) = navigationState,
                  connectedHost?.id == host.id,
                  generation == nil || generation == refreshGeneration
            else {
                return navigationState
            }
            latestSnapshot = snapshot
            navigationState = .panePicker(
                PanePickerState(
                    host: picker.host,
                    origin: picker.origin,
                    snapshot: snapshot,
                    attachedTerminal: refreshedPanePickerAttachment(
                        picker.attachedTerminal,
                        in: snapshot
                    )
                )
            )
        } catch {
            guard case let .panePicker(picker) = navigationState,
                  generation == nil || generation == refreshGeneration
            else {
                return navigationState
            }
            navigationState = .panePicker(
                PanePickerState(
                    host: picker.host,
                    origin: picker.origin,
                    snapshot: picker.snapshot,
                    attachedTerminal: picker.attachedTerminal,
                    message: panePickerPresentableMessage(for: error)
                )
            )
        }
        return navigationState
    }

}

extension HerdrPanePickerCoordinator: PanePickerCoordinating {}
