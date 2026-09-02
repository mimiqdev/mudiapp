import Foundation
import HerdrKit
@testable import Mudi

/// These aliases keep the phase contract focused on observations while the
/// implementation lives in the app target. The same production state is used
/// by RootViewModel and the shared Pane Picker view.
typealias Phase6NavigationState = PanePickerNavigationState
typealias Phase6PickerOrigin = PanePickerOrigin
typealias Phase6PanePickerState = PanePickerState
typealias Phase6AttachedTerminal = PanePickerAttachedTerminal
typealias Phase6TerminalContext = PanePickerTerminalContext

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
    func schedule(every interval: Int, _ work: @escaping Work) async -> UUID {
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

    func cancel(_ id: UUID) async {
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

typealias Phase6PaneControlReleasing = HerdrPaneControlReleasing

typealias MissingPhase6PanePickerApplication = HerdrPanePickerCoordinator<
    Phase6HerdrDiscovery,
    Phase6PaneControlTransport,
    Phase6TestScheduler
>

extension Phase6TestScheduler: PanePickerRefreshScheduling {}

extension HerdrPanePickerCoordinator: Phase6PanePickerApplication
where
    Discovery == Phase6HerdrDiscovery,
    Transport == Phase6PaneControlTransport,
    Scheduler == Phase6TestScheduler {}

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
