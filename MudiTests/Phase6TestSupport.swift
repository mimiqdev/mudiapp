import Foundation
import HerdrKit
@testable import Mudi

/// The navigation contract for the tests-first Phase 6 slice. The production
/// implementation can replace this compile-only seam with the root model and
/// one shared Pane Picker without changing the observations under test.
enum Phase6NavigationState: Equatable, Sendable {
    case hosts([Host])
    case legacyHerdrBrowser(HerdrBrowserState)
    case panePicker(Phase6PanePickerState)
    case terminal(Phase6TerminalContext)
}

enum Phase6PickerOrigin: Equatable, Sendable {
    case host
    case terminal
}

struct Phase6PanePickerState: Equatable, Sendable {
    let host: Host
    let origin: Phase6PickerOrigin
    let snapshot: HerdrSnapshot
    let attachedTerminal: Phase6AttachedTerminal?
}

struct Phase6AttachedTerminal: Equatable, Sendable {
    let host: Host
    let session: HerdrSession
    let pane: Pane
}

enum Phase6TerminalContext: Equatable, Sendable {
    case ordinary(host: Host)
    case attached(Phase6AttachedTerminal)
}

protocol Phase6PanePickerApplication: Sendable {
    func connect(to host: Host) async throws -> Phase6NavigationState
    func openPicker(from origin: Phase6PickerOrigin) async -> Phase6NavigationState
    func refreshPicker() async -> Phase6NavigationState
    func dismissPicker() async -> Phase6NavigationState
    func selectPane(_ paneID: Pane.ID) async -> Phase6NavigationState
    func selectOrdinaryTerminal() async -> Phase6NavigationState
}

enum Phase6Operation: Equatable, Sendable {
    case connect(Host)
    case discover(Host)
    case releaseControl(Pane.ID)
    case takeover(sessionID: HerdrSession.ID, paneID: Pane.ID)
    case disconnect
}

actor Phase6OperationRecorder {
    private var recordedOperations: [Phase6Operation] = []

    func record(_ operation: Phase6Operation) {
        recordedOperations.append(operation)
    }

    func operations() -> [Phase6Operation] {
        recordedOperations
    }
}

/// A virtual clock and scheduler. Tests advance it explicitly, so refresh
/// contracts never depend on wall-clock sleeps or task polling.
struct Phase6TestClock: Equatable, Sendable {
    private(set) var tick = 0

    mutating func advance(by amount: Int) {
        tick += amount
    }
}

actor Phase6TestScheduler {
    typealias Work = @Sendable () async -> Void

    private struct Job {
        let interval: Int
        var nextTick: Int
        let work: Work
    }

    private var clock = Phase6TestClock()
    private var jobs: [UUID: Job] = [:]
    private var jobOrder: [UUID] = []

    @discardableResult
    func schedule(every interval: Int, _ work: @escaping Work) -> UUID {
        precondition(interval > 0)
        let id = UUID()
        jobs[id] = Job(
            interval: interval,
            nextTick: clock.tick + interval,
            work: work
        )
        jobOrder.append(id)
        return id
    }

    func cancel(_ id: UUID) {
        jobs[id] = nil
        jobOrder.removeAll { $0 == id }
    }

    func advance(by amount: Int) async {
        guard amount >= 0 else { return }
        clock.advance(by: amount)

        while let id = nextDueJobID() {
            guard var job = jobs[id] else { continue }
            job.nextTick += job.interval
            jobs[id] = job
            await job.work()
        }
    }

    func scheduledJobCount() -> Int {
        jobs.count
    }

    func currentTick() -> Int {
        clock.tick
    }

    private func nextDueJobID() -> UUID? {
        jobOrder.first { id in
            guard let job = jobs[id] else { return false }
            return job.nextTick <= clock.tick
        }
    }
}

/// A deterministic discovery boundary fed by snapshots decoded from the
/// recorded Phase 3 Herdr command transcripts. The last snapshot is reused
/// after the sequence is exhausted, matching a stable later observation.
actor Phase6HerdrDiscovery: HerdrDiscovering {
    private let snapshots: [HerdrSnapshot]
    private let recorder: Phase6OperationRecorder
    private var nextSnapshotIndex = 0

    init(
        snapshots: [HerdrSnapshot],
        recorder: Phase6OperationRecorder
    ) {
        self.snapshots = snapshots
        self.recorder = recorder
    }

    func snapshot(for host: Host) async throws -> HerdrSnapshot {
        await recorder.record(.discover(host))
        guard !snapshots.isEmpty else {
            return HerdrSnapshot(sessions: [])
        }

        let index = min(nextSnapshotIndex, snapshots.count - 1)
        nextSnapshotIndex += 1
        return snapshots[index]
    }
}

/// A terminal/control fake that records the ordering boundary required when a
/// Picker changes panes. It intentionally exposes release separately from
/// TerminalTransport so the eventual coordinator must make that ordering
/// explicit rather than relying on a UI callback side effect.
actor Phase6PaneControlTransport: TerminalTransport,
    HerdrSessionAwareTerminalTransport,
    Phase6PaneControlReleasing
{
    nonisolated let kind: ActiveTransport = .ssh
    private let recorder: Phase6OperationRecorder
    private var connected = false
    private var attachedPaneID: Pane.ID?

    init(recorder: Phase6OperationRecorder) {
        self.recorder = recorder
    }

    func connect(to host: Host) async throws {
        connected = true
        await recorder.record(.connect(host))
    }

    func attach(to pane: Pane) async throws {
        attachedPaneID = pane.id
        await recorder.record(.takeover(sessionID: "", paneID: pane.id))
    }

    func attach(to pane: Pane, in session: HerdrSession) async throws {
        attachedPaneID = pane.id
        await recorder.record(
            .takeover(sessionID: session.id, paneID: pane.id)
        )
    }

    func releaseControl(for paneID: Pane.ID) async {
        attachedPaneID = nil
        await recorder.record(.releaseControl(paneID))
    }

    func send(_: [UInt8]) async throws {}

    func resize(columns _: Int, rows _: Int) async throws {}

    func disconnect() async {
        connected = false
        attachedPaneID = nil
        await recorder.record(.disconnect)
    }

    func isConnected() -> Bool {
        connected
    }

    func attachedPane() -> Pane.ID? {
        attachedPaneID
    }
}

protocol Phase6PaneControlReleasing: Sendable {
    func releaseControl(for paneID: Pane.ID) async
}

/// Compile-only scaffold for the tests-first step. It keeps the old browser
/// result, drops recorded agent fields in its temporary Picker projection, and
/// leaves refresh/release/dismiss behavior incomplete so the Phase 6 tests are
/// red until the production navigation and coordinator are implemented.
actor MissingPhase6PanePickerApplication: Phase6PanePickerApplication {
    let discovery: Phase6HerdrDiscovery
    let transport: Phase6PaneControlTransport
    let scheduler: Phase6TestScheduler

    private var connectedHost: Host?
    private var latestSnapshot: HerdrSnapshot?
    private var navigationState: Phase6NavigationState = .hosts([])
    private var scheduledRefreshID: UUID?

    init(
        discovery: Phase6HerdrDiscovery,
        transport: Phase6PaneControlTransport,
        scheduler: Phase6TestScheduler
    ) {
        self.discovery = discovery
        self.transport = transport
        self.scheduler = scheduler
    }

    func connect(to host: Host) async throws -> Phase6NavigationState {
        connectedHost = host
        try await transport.connect(to: host)
        do {
            latestSnapshot = try await discovery.snapshot(for: host)
        } catch {
            latestSnapshot = nil
        }
        navigationState = .legacyHerdrBrowser(
            legacyBrowserState(for: latestSnapshot ?? HerdrSnapshot(sessions: []))
        )
        return navigationState
    }

    func openPicker(from origin: Phase6PickerOrigin) async -> Phase6NavigationState {
        await cancelRefresh()
        guard let host = connectedHost else {
            navigationState = .panePicker(
                Phase6PanePickerState(
                    host: phase6Host(),
                    origin: origin,
                    snapshot: HerdrSnapshot(sessions: []),
                    attachedTerminal: nil
                )
            )
            return navigationState
        }

        let attachedTerminal: Phase6AttachedTerminal?
        if origin == .terminal,
           case let .terminal(.attached(attached)) = navigationState {
            attachedTerminal = attached
        } else {
            attachedTerminal = nil
        }

        let picker = Phase6PanePickerState(
            host: host,
            origin: origin,
            snapshot: incompleteProjection(
                from: latestSnapshot ?? HerdrSnapshot(sessions: [])
            ),
            attachedTerminal: attachedTerminal
        )
        navigationState = .panePicker(picker)

        // The future product must replace this no-op with scheduled discovery.
        scheduledRefreshID = await scheduler.schedule(every: 1) {}
        return navigationState
    }

    func refreshPicker() async -> Phase6NavigationState {
        // Deliberately no-op until the Picker owns the official discovery path.
        navigationState
    }

    func dismissPicker() async -> Phase6NavigationState {
        guard case let .panePicker(picker) = navigationState else {
            return navigationState
        }
        await cancelRefresh()

        switch picker.origin {
        case .host:
            // The missing product disconnects neither the Host nor its shell.
            navigationState = .hosts([picker.host])
        case .terminal:
            // The old navigation loses pane context instead of restoring it.
            if let attachedTerminal = picker.attachedTerminal {
                navigationState = .terminal(
                    .ordinary(host: attachedTerminal.host)
                )
            } else {
                navigationState = .hosts([picker.host])
            }
        }
        return navigationState
    }

    func selectPane(_ paneID: Pane.ID) async -> Phase6NavigationState {
        guard case let .panePicker(picker) = navigationState,
              let location = paneLocation(
                  in: picker.snapshot,
                  paneID: paneID
              )
        else {
            return navigationState
        }

        // Deliberately missing: the old control must be released first.
        try? await transport.attach(to: location.pane, in: location.session)
        await cancelRefresh()
        navigationState = .terminal(
            .attached(
                Phase6AttachedTerminal(
                    host: picker.host,
                    session: location.session,
                    pane: location.pane
                )
            )
        )
        return navigationState
    }

    func selectOrdinaryTerminal() async -> Phase6NavigationState {
        guard case let .panePicker(picker) = navigationState,
              let location = paneLocation(in: picker.snapshot, paneID: firstPaneID(in: picker.snapshot))
        else {
            return navigationState
        }

        // Deliberately models the pre-picker mistake: ordinary terminal takes
        // over a pane instead of using the existing Host shell directly.
        try? await transport.attach(to: location.pane, in: location.session)
        await cancelRefresh()
        navigationState = .terminal(
            .attached(
                Phase6AttachedTerminal(
                    host: picker.host,
                    session: location.session,
                    pane: location.pane
                )
            )
        )
        return navigationState
    }

    func currentState() -> Phase6NavigationState {
        navigationState
    }

    private func cancelRefresh() async {
        guard let scheduledRefreshID else { return }
        await scheduler.cancel(scheduledRefreshID)
        self.scheduledRefreshID = nil
    }

    private func legacyBrowserState(for snapshot: HerdrSnapshot) -> HerdrBrowserState {
        switch snapshot.sessions.count {
        case 0:
            return .empty
        case 1:
            return .panes(session: snapshot.sessions[0], message: nil)
        default:
            return .sessions(snapshot.sessions.map(HerdrSessionSummary.init(session:)))
        }
    }

    private func incompleteProjection(from snapshot: HerdrSnapshot) -> HerdrSnapshot {
        HerdrSnapshot(
            sessions: snapshot.sessions.map { session in
                HerdrSession(
                    id: session.id,
                    name: session.name,
                    isDefault: session.isDefault,
                    workspaces: session.workspaces.map { workspace in
                        Workspace(
                            id: workspace.id,
                            name: workspace.name,
                            tabs: workspace.tabs.map { tab in
                                Tab(
                                    id: tab.id,
                                    name: tab.name,
                                    panes: tab.panes.map { pane in
                                        Pane(id: pane.id, title: pane.title)
                                    }
                                )
                            }
                        )
                    }
                )
            }
        )
    }

    private func firstPaneID(in snapshot: HerdrSnapshot) -> Pane.ID? {
        snapshot.sessions
            .flatMap(phase6Panes(in:))
            .first?.id
    }

    private func paneLocation(
        in snapshot: HerdrSnapshot,
        paneID: Pane.ID?
    ) -> (session: HerdrSession, pane: Pane)? {
        guard let paneID else { return nil }
        for session in snapshot.sessions {
            if let pane = phase6Panes(in: session).first(where: { $0.id == paneID }) {
                return (session, pane)
            }
        }
        return nil
    }
}

func makeMissingPhase6Application(
    snapshots: [HerdrSnapshot],
    recorder: Phase6OperationRecorder = Phase6OperationRecorder(),
    transport: Phase6PaneControlTransport? = nil,
    scheduler: Phase6TestScheduler = Phase6TestScheduler()
) -> MissingPhase6PanePickerApplication {
    let transport = transport ?? Phase6PaneControlTransport(recorder: recorder)
    return MissingPhase6PanePickerApplication(
        discovery: Phase6HerdrDiscovery(
            snapshots: snapshots,
            recorder: recorder
        ),
        transport: transport,
        scheduler: scheduler
    )
}

func phase6Snapshot(from fixture: Phase3HerdrFixture) -> HerdrSnapshot {
    HerdrSnapshot(sessions: fixture.sessions)
}

func phase6Panes(in snapshot: HerdrSnapshot) -> [Pane] {
    snapshot.sessions.flatMap(phase6Panes(in:))
}

func phase6Panes(in session: HerdrSession) -> [Pane] {
    session.workspaces.flatMap { workspace in
        workspace.tabs.flatMap(\.panes)
    }
}

func phase6Host(id: UUID = UUID()) -> Host {
    Host(
        id: id,
        displayName: "Phase 6 Host",
        hostname: "phase6.example.test",
        port: 2222,
        username: "developer",
        preferredTransport: .ssh
    )
}
