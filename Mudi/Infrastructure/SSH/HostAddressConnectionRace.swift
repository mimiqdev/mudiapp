import Foundation
import HerdrKit

/// A clock seam for the multi-address network race. Human authentication and
/// TOFU prompts are intentionally outside this boundary.
protocol HostAddressRaceClock: Sendable {
    func sleep(for duration: Duration) async throws
    func now() async -> Duration
}

struct ContinuousHostAddressRaceClock: HostAddressRaceClock {
    private let start: ContinuousClock.Instant

    init(start: ContinuousClock.Instant = .now) {
        self.start = start
    }

    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }

    func now() async -> Duration {
        ContinuousClock.now - start
    }
}

/// Opens only the network path for one endpoint. Implementations must not
/// authenticate, ask for credentials, or validate a host key here.
protocol HostAddressNetworkConnecting: Sendable {
    func connectNetwork(to host: Host) async throws -> any HostAddressNetworkConnection
}

/// The pre-authentication network socket won by a Host address race. The
/// winner remains open and is handed to the SSH adapter for authentication;
/// only losing sockets are closed by the race.
protocol HostAddressNetworkConnection: Sendable {
    var target: HostAddress { get }
    func close() async
}

/// The SSH adapter seam that consumes the winning pre-authentication socket.
/// Implementations must not dial a second socket for the same target.
protocol HostAddressNetworkHandoff: Sendable {
    func connect(
        to host: Host,
        credentials: SSHCredentials,
        hostKeyDecision: @escaping @Sendable (String) async -> HostKeyDecision,
        using networkConnection: any HostAddressNetworkConnection
    ) async throws -> any PTYChannel
}

struct HostAddressRacePolicy: Equatable, Sendable {
    let preferredExclusiveWindow: Duration
    let backupStagger: Duration
    /// One budget shared by the preferred attempt and every backup. It starts
    /// when the preferred network attempt starts and is never reset.
    let networkDeadline: Duration

    static let `default` = HostAddressRacePolicy(
        preferredExclusiveWindow: .seconds(2),
        backupStagger: .milliseconds(500),
        networkDeadline: .seconds(30)
    )
}

enum HostAddressAttemptOutcome: Equatable, Sendable {
    case notStarted
    case started
    case succeeded
    case failed(String)
    case timedOut
    case cancelled
}

struct HostAddressAttemptResult: Equatable, Sendable {
    let address: HostAddress
    let startedAt: Duration?
    let outcome: HostAddressAttemptOutcome
}

enum HostAddressConnectionRaceError: Error, Equatable, LocalizedError, Sendable {
    case invalidAddressList
    case allAttemptsFailed([HostAddressAttemptResult])
    case deadlineExceeded([HostAddressAttemptResult])

    var outcomes: [HostAddressAttemptResult] {
        switch self {
        case .invalidAddressList:
            []
        case let .allAttemptsFailed(outcomes), let .deadlineExceeded(outcomes):
            outcomes
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidAddressList:
            "No valid SSH address is configured."
        case .allAttemptsFailed:
            "Every configured SSH address failed to establish a network connection."
        case .deadlineExceeded:
            "The configured SSH addresses did not establish a network connection in time."
        }
    }
}

enum HostAddressRaceProgress: Equatable, Sendable {
    case preferred(address: HostAddress, elapsed: Duration)
    case racing(addresses: [HostAddress], elapsed: Duration)
    case selected(address: HostAddress, elapsed: Duration)
    case failed(outcomes: [HostAddressAttemptResult])
}

struct HostAddressConnectionRaceResult: Sendable {
    let target: HostAddress
    let connection: any HostAddressNetworkConnection
    let outcomes: [HostAddressAttemptResult]
}

enum HostAddressConnectionRace {
    static func connect(
        addresses: [HostAddress],
        policy: HostAddressRacePolicy = .default,
        clock: any HostAddressRaceClock = ContinuousHostAddressRaceClock(),
        using connector: @escaping @Sendable (
            HostAddress
        ) async throws -> any HostAddressNetworkConnection,
        onProgress: (@Sendable (HostAddressRaceProgress) async -> Void)? = nil
    ) async throws -> HostAddressConnectionRaceResult {
        guard !addresses.isEmpty,
              addresses.allSatisfy({
                  !$0.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              })
        else {
            throw HostAddressConnectionRaceError.invalidAddressList
        }

        let registry = HostAddressRaceRegistry()
        let cancellation = HostAddressRaceCancellation()
        let runner = HostAddressRaceRunner(
            addresses: addresses,
            policy: policy,
            clock: clock,
            connector: connector,
            onProgress: onProgress,
            registry: registry,
            cancellation: cancellation
        )
        return try await withTaskCancellationHandler {
            try await runner.run()
        } onCancel: {
            Task {
                await registry.cancelAll()
                await cancellation.cancel()
            }
        }
    }
}

private enum HostAddressRaceEvent: Sendable {
    case backupWindowExpired
    case backupLaunch
    case deadline
    case failed(index: Int, message: String)
    case cancelled(index: Int)
    case lost(index: Int)
    case won(index: Int)
    case cancelledRace
}

private final class HostAddressRaceRunner: @unchecked Sendable {
    let addresses: [HostAddress]
    let policy: HostAddressRacePolicy
    let clock: any HostAddressRaceClock
    let connector: @Sendable (HostAddress) async throws -> any HostAddressNetworkConnection
    let onProgress: (@Sendable (HostAddressRaceProgress) async -> Void)?
    let registry: HostAddressRaceRegistry
    let cancellation: HostAddressRaceCancellation

    var continuation: AsyncStream<HostAddressRaceEvent>.Continuation!
    var outcomes: [HostAddressAttemptResult]
    var attemptTasks: [Int: Task<Void, Never>] = [:]
    var timerTasks: [Task<Void, Never>] = []
    var backupPhaseStarted = false
    var nextBackupIndex = 1
    var backupLaunchScheduled = false
    var activeAttempts = 0
    var raceStartedAt: Duration?
    var didCleanUp = false

    init(
        addresses: [HostAddress],
        policy: HostAddressRacePolicy,
        clock: any HostAddressRaceClock,
        connector: @escaping @Sendable (
            HostAddress
        ) async throws -> any HostAddressNetworkConnection,
        onProgress: (@Sendable (HostAddressRaceProgress) async -> Void)?,
        registry: HostAddressRaceRegistry,
        cancellation: HostAddressRaceCancellation
    ) {
        self.addresses = addresses
        self.policy = policy
        self.clock = clock
        self.connector = connector
        self.onProgress = onProgress
        self.registry = registry
        self.cancellation = cancellation
        outcomes = addresses.map {
            HostAddressAttemptResult(
                address: $0,
                startedAt: nil,
                outcome: .notStarted
            )
        }
    }

    func run() async throws -> HostAddressConnectionRaceResult {
        var continuation: AsyncStream<HostAddressRaceEvent>.Continuation!
        let events = AsyncStream<HostAddressRaceEvent> { continuation = $0 }
        self.continuation = continuation
        await cancellation.install(continuation)
        await beginAttempt(0)

        do {
            for await event in events {
                try Task.checkCancellation()
                if let result = try await handle(event) {
                    return result
                }
            }
            throw CancellationError()
        } catch {
            let waitsForCancelledAttempts: Bool
            if let raceError = error as? HostAddressConnectionRaceError {
                switch raceError {
                case .deadlineExceeded:
                    waitsForCancelledAttempts = false
                case .invalidAddressList, .allAttemptsFailed:
                    waitsForCancelledAttempts = true
                }
            } else {
                waitsForCancelledAttempts = true
            }
            await cleanUp(waitForCancelledAttempts: waitsForCancelledAttempts)
            throw error
        }
    }

    private func handle(
        _ event: HostAddressRaceEvent
    ) async throws -> HostAddressConnectionRaceResult? {
        switch event {
        case .cancelledRace:
            throw CancellationError()
        case .backupWindowExpired:
            await startBackupPhase()
        case .backupLaunch:
            await launchScheduledBackup()
        case let .failed(index, message):
            try await handleFailure(index: index, message: message)
        case let .cancelled(index):
            try await handleCancellation(index: index)
        case let .lost(index):
            handleLost(index: index)
        case let .won(index):
            return try await handleWinner(index: index)
        case .deadline:
            try await handleDeadline()
        }
        return nil
    }

    private func beginAttempt(_ index: Int) async {
        guard index < addresses.count,
              outcomes[index].outcome == .notStarted
        else { return }
        let startedAt = await clock.now()
        if index == 0 {
            raceStartedAt = startedAt
            schedule(policy.preferredExclusiveWindow, .backupWindowExpired)
            schedule(policy.networkDeadline, .deadline)
        }
        updateOutcome(index, startedAt: startedAt, outcome: .started)
        activeAttempts += 1

        let address = addresses[index]
        let task = Task { [self] in
            do {
                let connection = try await connector(address)
                let won = await registry.claim(index: index, connection: connection)
                continuation.yield(won ? .won(index: index) : .lost(index: index))
            } catch is CancellationError {
                continuation.yield(.cancelled(index: index))
            } catch {
                continuation.yield(
                    .failed(index: index, message: Self.failureMessage(error))
                )
            }
        }
        attemptTasks[index] = task
        if index > 0 {
            scheduleNextBackup()
        }

        let elapsed = await elapsed()
        if index == 0 {
            await report(.preferred(address: addresses[index], elapsed: elapsed))
        } else {
            let activeAddresses = outcomes.compactMap {
                $0.outcome == .started ? $0.address : nil
            }
            await report(.racing(addresses: activeAddresses, elapsed: elapsed))
        }
    }

    private func schedule(_ duration: Duration, _ event: HostAddressRaceEvent) {
        let task = Task { [self] in
            do {
                try await clock.sleep(for: duration)
                continuation.yield(event)
            } catch is CancellationError {
                // The race owns cancellation and performs cleanup.
            } catch {
                continuation.yield(.cancelledRace)
            }
        }
        timerTasks.append(task)
    }

    private func startBackupPhase() async {
        guard !backupPhaseStarted else { return }
        backupPhaseStarted = true
        await launchNextBackup()
    }

    private func launchScheduledBackup() async {
        backupLaunchScheduled = false
        await launchNextBackup()
    }

    private func launchNextBackup() async {
        guard nextBackupIndex < addresses.count else { return }
        let index = nextBackupIndex
        nextBackupIndex += 1
        await beginAttempt(index)
    }

    private func scheduleNextBackup() {
        guard nextBackupIndex < addresses.count,
              !backupLaunchScheduled
        else { return }
        backupLaunchScheduled = true
        schedule(policy.backupStagger, .backupLaunch)
    }

    private func handleFailure(index: Int, message: String) async throws {
        guard outcomes[index].outcome == .started else { return }
        activeAttempts -= 1
        updateOutcome(index, outcome: .failed(message))
        if index == 0 {
            await startBackupPhase()
        } else {
            scheduleNextBackup()
        }
        try await finishIfNoWork()
    }

    private func handleCancellation(index: Int) async throws {
        guard outcomes[index].outcome == .started else { return }
        activeAttempts -= 1
        updateOutcome(index, outcome: .cancelled)
        try await finishIfNoWork()
    }

    private func handleLost(index: Int) {
        guard outcomes[index].outcome == .started else { return }
        activeAttempts -= 1
        updateOutcome(index, outcome: .cancelled)
    }

    private func handleWinner(
        index: Int
    ) async throws -> HostAddressConnectionRaceResult? {
        guard outcomes[index].outcome == .started,
              await registry.winnerIndex() == index
        else { return nil }
        activeAttempts -= 1
        updateOutcome(index, outcome: .succeeded)
        guard let connection = await registry.closeLosers(keeping: index) else {
            throw HostAddressConnectionRaceError.allAttemptsFailed(outcomes)
        }
        await cleanUp(keeping: index)
        await report(
            .selected(address: addresses[index], elapsed: await elapsed())
        )
        return HostAddressConnectionRaceResult(
            target: addresses[index],
            connection: connection,
            outcomes: outcomes
        )
    }

    private func handleDeadline() async throws {
        for index in outcomes.indices {
            switch outcomes[index].outcome {
            case .notStarted, .started:
                updateOutcome(index, outcome: .timedOut)
            case .succeeded, .failed, .timedOut, .cancelled:
                break
            }
        }
        await report(.failed(outcomes: outcomes))
        throw HostAddressConnectionRaceError.deadlineExceeded(outcomes)
    }

    private func finishIfNoWork() async throws {
        guard activeAttempts == 0,
              nextBackupIndex >= addresses.count,
              !backupLaunchScheduled
        else { return }
        await report(.failed(outcomes: outcomes))
        throw HostAddressConnectionRaceError.allAttemptsFailed(outcomes)
    }

    private func updateOutcome(
        _ index: Int,
        startedAt: Duration? = nil,
        outcome: HostAddressAttemptOutcome
    ) {
        outcomes[index] = HostAddressAttemptResult(
            address: outcomes[index].address,
            startedAt: startedAt ?? outcomes[index].startedAt,
            outcome: outcome
        )
    }

    private func elapsed() async -> Duration {
        guard let raceStartedAt else { return .zero }
        return await clock.now() - raceStartedAt
    }

    private func report(_ progress: HostAddressRaceProgress) async {
        await onProgress?(progress)
    }

    private func cleanUp(
        keeping winner: Int? = nil,
        waitForCancelledAttempts: Bool = true
    ) async {
        guard !didCleanUp else { return }
        didCleanUp = true
        timerTasks.forEach { $0.cancel() }
        for (index, task) in attemptTasks where index != winner {
            task.cancel()
            if outcomes[index].outcome == .started
                || outcomes[index].outcome == .notStarted {
                updateOutcome(index, outcome: .cancelled)
            }
        }
        if winner == nil {
            await registry.cancelAll()
        } else {
            for index in outcomes.indices where index != winner {
                if outcomes[index].outcome == .notStarted {
                    updateOutcome(index, outcome: .cancelled)
                }
            }
            _ = await registry.closeLosers(keeping: winner)
        }
        if waitForCancelledAttempts {
            for task in timerTasks {
                await task.value
            }
            // Connector cancellation is advisory. Registry cancellation and
            // the selected-index gate close any late socket without making
            // the race wait on an uncancellable third-party task.
        }
        continuation.finish()
    }

    private static func failureMessage(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return description
        }
        return String(describing: error)
    }
}

private actor HostAddressRaceRegistry {
    private var connections: [Int: any HostAddressNetworkConnection] = [:]
    private var selectedIndex: Int?
    private var cancelled = false

    func claim(index: Int, connection: any HostAddressNetworkConnection) async -> Bool {
        guard !cancelled, selectedIndex == nil else {
            await connection.close()
            return false
        }
        connections[index] = connection
        selectedIndex = index
        return true
    }

    func winnerIndex() -> Int? { selectedIndex }

    func closeLosers(keeping winner: Int?) async -> (any HostAddressNetworkConnection)? {
        let winnerConnection = winner.flatMap { connections[$0] }
        let losers = connections.filter { $0.key != winner }.map(\.value)
        for loser in losers {
            await loser.close()
        }
        connections.removeAll()
        return winnerConnection
    }

    func cancelAll() async {
        cancelled = true
        let values = Array(connections.values)
        connections.removeAll()
        selectedIndex = nil
        for connection in values {
            await connection.close()
        }
    }
}

private actor HostAddressRaceCancellation {
    private var continuation: AsyncStream<HostAddressRaceEvent>.Continuation?
    private var wasCancelled = false

    func install(_ continuation: AsyncStream<HostAddressRaceEvent>.Continuation) {
        self.continuation = continuation
        if wasCancelled {
            continuation.yield(.cancelledRace)
        }
    }

    func cancel() {
        wasCancelled = true
        continuation?.yield(.cancelledRace)
    }
}
