import Foundation
import HerdrKit

/// A clock seam for serial multi-address network attempts. Human
/// authentication and TOFU prompts are intentionally outside this boundary.
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

/// The pre-authentication network socket for one Host address. The
/// coordinator closes it before handing the selected target to the existing
/// SSH adapter; serial callers never retain more than one candidate.
protocol HostAddressNetworkConnection: Sendable {
    var target: HostAddress { get }
    func close() async
}

struct HostAddressRacePolicy: Equatable, Sendable {
    /// The maximum time given to one network attempt before it is cancelled
    /// and the next saved address is tried.
    let perAddressTimeout: Duration
    /// A single budget shared by the complete ordered sequence.
    let networkDeadline: Duration

    init(
        perAddressTimeout: Duration = .seconds(5),
        networkDeadline: Duration = .seconds(30)
    ) {
        self.perAddressTimeout = perAddressTimeout
        self.networkDeadline = networkDeadline
    }

    /// Source compatibility for the former parallel-race policy. The first
    /// parameter now supplies the serial per-address timeout; the stagger is
    /// deliberately ignored because serial attempts never overlap.
    init(
        preferredExclusiveWindow: Duration,
        backupStagger _: Duration,
        networkDeadline: Duration
    ) {
        self.init(
            perAddressTimeout: preferredExclusiveWindow,
            networkDeadline: networkDeadline
        )
    }

    /// Compatibility accessors for callers that still display the old policy.
    var preferredExclusiveWindow: Duration { perAddressTimeout }
    var backupStagger: Duration { .zero }

    static let `default` = HostAddressRacePolicy()
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
    case attempting(address: HostAddress, elapsed: Duration)
    /// Retained as a source-compatible progress case for older observers. A
    /// serial race does not emit it.
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
                await cancellation.cancel()
            }
        }
    }
}

private enum HostAddressRaceEvent: Sendable {
    case succeeded(index: Int)
    case failed(index: Int, message: String)
    case cancelled(index: Int)
    case timedOut(index: Int)
    case deadline
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
    var timeoutTasks: [Int: Task<Void, Never>] = [:]
    var deadlineTask: Task<Void, Never>?
    var currentIndex: Int?
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

        let startedAt = await clock.now()
        raceStartedAt = startedAt
        scheduleDeadline(from: startedAt)
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
            let waitForCancelledAttempts: Bool
            if let raceError = error as? HostAddressConnectionRaceError {
                switch raceError {
                case .deadlineExceeded:
                    waitForCancelledAttempts = false
                case .invalidAddressList, .allAttemptsFailed:
                    waitForCancelledAttempts = true
                }
            } else {
                waitForCancelledAttempts = true
            }
            await cleanUp(
                keeping: nil,
                waitForCancelledAttempts: waitForCancelledAttempts
            )
            throw error
        }
    }

    private func handle(
        _ event: HostAddressRaceEvent
    ) async throws -> HostAddressConnectionRaceResult? {
        switch event {
        case let .succeeded(index):
            return try await handleSuccess(index: index)
        case let .failed(index, message):
            try await handleFailure(index: index, message: message)
        case let .cancelled(index):
            try await handleCancellation(index: index)
        case let .timedOut(index):
            try await handleTimeout(index: index)
        case .deadline:
            try await handleDeadline()
        case .cancelledRace:
            throw CancellationError()
        }
        return nil
    }

    private func beginAttempt(_ index: Int) async {
        guard index < addresses.count,
              outcomes[index].outcome == .notStarted
        else { return }

        currentIndex = index
        let startedAt = await clock.now()
        updateOutcome(index, startedAt: startedAt, outcome: .started)
        if index == 0 {
            await report(.preferred(address: addresses[index], elapsed: startedAt))
        } else {
            await report(.attempting(address: addresses[index], elapsed: startedAt))
        }

        let address = addresses[index]
        let task = Task { [self] in
            do {
                let connection = try await connector(address)
                guard await registry.claim(index: index, connection: connection) else {
                    continuation.yield(.cancelled(index: index))
                    return
                }
                continuation.yield(.succeeded(index: index))
            } catch is CancellationError {
                continuation.yield(.cancelled(index: index))
            } catch {
                continuation.yield(
                    .failed(index: index, message: Self.failureMessage(error))
                )
            }
        }
        attemptTasks[index] = task

        let remaining = await remainingBudget()
        let timeout = min(policy.perAddressTimeout, remaining)
        scheduleTimeout(index: index, after: timeout)
    }

    private func scheduleDeadline(from startedAt: Duration) {
        deadlineTask = Task { [self] in
            do {
                try await clock.sleep(for: policy.networkDeadline)
                continuation.yield(.deadline)
            } catch is CancellationError {
                // The race owns cancellation and performs cleanup.
            } catch {
                continuation.yield(.cancelledRace)
            }
        }
        _ = startedAt
    }

    private func scheduleTimeout(index: Int, after duration: Duration) {
        timeoutTasks[index] = Task { [self] in
            do {
                try await clock.sleep(for: duration)
                continuation.yield(.timedOut(index: index))
            } catch is CancellationError {
                // The attempt completed or the race was cancelled.
            } catch {
                continuation.yield(.cancelledRace)
            }
        }
    }

    private func handleSuccess(index: Int) async throws -> HostAddressConnectionRaceResult? {
        guard currentIndex == index,
              outcomes[index].outcome == .started
        else { return nil }
        await finishAttempt(index, retireConnection: false)
        updateOutcome(index, outcome: .succeeded)
        await cleanUp(keeping: index)
        guard let connection = await registry.connection(for: index) else {
            throw HostAddressConnectionRaceError.allAttemptsFailed(outcomes)
        }
        await report(
            .selected(address: addresses[index], elapsed: await clock.now())
        )
        return HostAddressConnectionRaceResult(
            target: addresses[index],
            connection: connection,
            outcomes: outcomes
        )
    }

    private func handleFailure(index: Int, message: String) async throws {
        guard currentIndex == index,
              outcomes[index].outcome == .started
        else { return }
        await finishAttempt(index, retireConnection: false)
        updateOutcome(index, outcome: .failed(message))
        try await startNextAttempt(after: index)
    }

    private func handleTimeout(index: Int) async throws {
        guard currentIndex == index,
              outcomes[index].outcome == .started
        else { return }
        await finishAttempt(index, retireConnection: true)
        updateOutcome(index, outcome: .timedOut)
        try await startNextAttempt(after: index)
    }

    private func handleCancellation(index: Int) async throws {
        guard currentIndex == index,
              outcomes[index].outcome == .started
        else { return }
        throw CancellationError()
    }

    private func startNextAttempt(after index: Int) async throws {
        let nextIndex = index + 1
        guard nextIndex < addresses.count else {
            await report(.failed(outcomes: outcomes))
            throw HostAddressConnectionRaceError.allAttemptsFailed(outcomes)
        }
        guard await remainingBudget() > .zero else {
            try await handleDeadline()
            return
        }
        await beginAttempt(nextIndex)
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

    private func finishAttempt(_ index: Int, retireConnection: Bool) async {
        // Do not await an arbitrary connector after requesting cancellation.
        // The registry is authoritative: a late result for a retired attempt
        // is closed by claim(), so the next serial address can start within
        // the timeout budget even if a third-party connector is not perfectly
        // cancellation-cooperative.
        timeoutTasks[index]?.cancel()
        timeoutTasks[index] = nil
        if retireConnection {
            await registry.retire(index: index)
        }
        attemptTasks[index]?.cancel()
    }

    private func remainingBudget() async -> Duration {
        guard let raceStartedAt else { return policy.networkDeadline }
        let elapsed = await clock.now() - raceStartedAt
        guard elapsed < policy.networkDeadline else { return .zero }
        return policy.networkDeadline - elapsed
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

    private func report(_ progress: HostAddressRaceProgress) async {
        await onProgress?(progress)
    }

    private func cleanUp(
        keeping winner: Int?,
        waitForCancelledAttempts: Bool = true
    ) async {
        guard !didCleanUp else { return }
        didCleanUp = true
        deadlineTask?.cancel()
        timeoutTasks.values.forEach { $0.cancel() }
        for (index, task) in attemptTasks where index != winner {
            task.cancel()
            if outcomes[index].outcome == .started
                || outcomes[index].outcome == .notStarted {
                updateOutcome(index, outcome: .cancelled)
            }
        }
        if let winner {
            await registry.closeAll(keeping: winner)
            for index in outcomes.indices where index != winner {
                if outcomes[index].outcome == .notStarted {
                    updateOutcome(index, outcome: .cancelled)
                }
            }
        } else {
            await registry.cancelAll()
        }
        if waitForCancelledAttempts {
            if let deadlineTask {
                await deadlineTask.value
            }
            for task in timeoutTasks.values {
                await task.value
            }
            // Connector tasks are deliberately not awaited here. Cancellation
            // is advisory at the task boundary; registry cancellation/retire
            // closes any connection that arrives after this race has moved on.
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
    private var retired: Set<Int> = []
    private var cancelled = false

    func claim(
        index: Int,
        connection: any HostAddressNetworkConnection
    ) async -> Bool {
        guard !cancelled, !retired.contains(index) else {
            await connection.close()
            return false
        }
        connections[index] = connection
        return true
    }

    func connection(for index: Int) -> (any HostAddressNetworkConnection)? {
        connections[index]
    }

    func retire(index: Int) async {
        retired.insert(index)
        guard let connection = connections.removeValue(forKey: index) else { return }
        await connection.close()
    }

    func closeAll(keeping winner: Int?) async {
        if let winner {
            // The winner is the only connection the caller may still consume;
            // every later result belongs to a race that is already settled.
            cancelled = true
            let loserEntries = connections.filter { $0.key != winner }
            connections = connections.filter { $0.key == winner }
            retired.formUnion(loserEntries.keys)
            for loser in loserEntries.values {
                await loser.close()
            }
        } else {
            await cancelAll()
        }
    }

    func cancelAll() async {
        cancelled = true
        let values = Array(connections.values)
        connections.removeAll()
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
