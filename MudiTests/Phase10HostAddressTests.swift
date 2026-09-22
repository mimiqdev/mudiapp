import Foundation
import HerdrKit
import XCTest
@testable import Mudi

final class Phase10HostAddressTests: XCTestCase {
    func testLegacyHostPayloadMigratesToOrderedAddressWithSharedPort() async throws {
        let url = temporaryHostURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let hostID = UUID()
        let legacy: [[String: Any]] = [[
            "id": hostID.uuidString,
            "displayName": "Legacy Mac",
            "hostname": "mac.example.test",
            "port": 2200,
            "username": "developer",
            "preferredTransport": "ssh",
        ]]
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try legacyData.write(to: url)

        let store = JSONHostStore(fileURL: url)
        let hosts = try await store.loadHosts()

        let host = try XCTUnwrap(hosts.first)
        XCTAssertEqual(host.id, hostID)
        XCTAssertEqual(host.addresses, [HostAddress(address: "mac.example.test")])
        XCTAssertEqual(host.port, 2200)
        XCTAssertEqual(host.addresses.first?.portOverride, nil)

        let migratedData = try Data(contentsOf: url)
        let migratedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: migratedData) as? [[String: Any]]
        )
        XCTAssertNotNil(migratedObject.first?["addresses"])
        XCTAssertNil(migratedObject.first?["hostname"])
    }

    func testAddressPortOverrideInheritsHostDefaultAndRoundTrips() throws {
        let host = Host(
            displayName: "Multi-path Mac",
            addresses: [
                HostAddress(address: "192.0.2.10"),
                HostAddress(address: "tail.example.test", portOverride: 2222),
            ],
            port: 22,
            username: "developer"
        )

        XCTAssertEqual(host.targeting(host.addresses[0]).effectivePort, 22)
        XCTAssertEqual(host.targeting(host.addresses[1]).effectivePort, 2222)

        let roundTrip = try JSONDecoder().decode(
            Host.self,
            from: JSONEncoder().encode(host)
        )
        XCTAssertEqual(roundTrip, host)
        XCTAssertEqual(
            roundTrip.addresses.map(\.portOverride),
            [nil, 2222]
        )
    }

    func testHostStoreRejectsEmptyAddressListAndBlankAddress() async throws {
        let url = temporaryHostURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = JSONHostStore(fileURL: url)
        let emptyHost = Host(
            displayName: "Invalid",
            addresses: [],
            port: 22,
            username: "developer"
        )
        let blankHost = Host(
            displayName: "Invalid",
            addresses: [HostAddress(address: "   ")],
            port: 22,
            username: "developer"
        )

        do {
            try await store.save(emptyHost)
            XCTFail("An empty address list must not be persisted")
        } catch is HostPersistenceError {
            // Expected contract failure.
        }
        do {
            try await store.save(blankHost)
            XCTFail("A blank address must not be persisted")
        } catch is HostPersistenceError {
            // Expected contract failure.
        }
    }

    func testPreferredAddressHasExclusiveWindowAndExplicitFailureStartsBackupsEarly() async throws {
        let clock = Phase10TestClock()
        let connector = Phase10RaceConnector(clock: clock)
        let addresses = [
            HostAddress(address: "preferred.example.test"),
            HostAddress(address: "backup-lan.example.test"),
            HostAddress(address: "backup-tailnet.example.test"),
        ]
        let policy = HostAddressRacePolicy(
            preferredExclusiveWindow: .seconds(2),
            backupStagger: .milliseconds(500),
            networkDeadline: .seconds(30)
        )
        let task = Task {
            try await HostAddressConnectionRace.connect(
                addresses: addresses,
                policy: policy,
                clock: clock,
                using: connector.connect
            )
        }

        await connector.waitUntilStarted(addresses[0])
        await clock.advance(by: .seconds(1.9))
        XCTAssertEqual(await connector.startedAddresses(), [addresses[0]])

        await connector.fail(addresses[0], message: "unreachable")
        await connector.waitUntilStarted(addresses[1])
        XCTAssertEqual(
            await connector.startedAddresses(),
            [addresses[0], addresses[1]]
        )

        await connector.succeed(addresses[1])
        let result = try await task.value
        XCTAssertEqual(result.target, addresses[1])
        await connector.assertCancelled(addresses[2])
    }

    func testPreferredRemainsEligibleWhileBackupsStartEvery500Milliseconds() async throws {
        let clock = Phase10TestClock()
        let connector = Phase10RaceConnector(clock: clock)
        let addresses = [
            HostAddress(address: "preferred.example.test"),
            HostAddress(address: "backup-one.example.test"),
            HostAddress(address: "backup-two.example.test"),
        ]
        let task = Task {
            try await HostAddressConnectionRace.connect(
                addresses: addresses,
                policy: .default,
                clock: clock,
                using: connector.connect
            )
        }

        await connector.waitUntilStarted(addresses[0])
        await clock.advance(by: .seconds(2))
        await connector.waitUntilStarted(addresses[1])
        await clock.advance(by: .milliseconds(500))
        await connector.waitUntilStarted(addresses[2])
        XCTAssertEqual(
            await connector.startedAddresses(),
            [addresses[0], addresses[1], addresses[2]]
        )

        await connector.succeed(addresses[0])
        let result = try await task.value
        XCTAssertEqual(result.target, addresses[0])
        await connector.assertCancelled(addresses[1])
        await connector.assertCancelled(addresses[2])
    }

    func testSharedThirtySecondDeadlineStartsAtPreferredAndDoesNotResetPerBackup() async throws {
        let clock = Phase10TestClock()
        let connector = Phase10RaceConnector(clock: clock)
        let addresses = (0..<4).map {
            HostAddress(address: "backup-\($0).example.test")
        }
        let task = Task {
            try await HostAddressConnectionRace.connect(
                addresses: addresses,
                policy: .default,
                clock: clock,
                using: connector.connect
            )
        }

        await connector.waitUntilStarted(addresses[0])
        await clock.advance(by: .seconds(2))
        await connector.waitUntilStarted(addresses[1])
        await clock.advance(by: .milliseconds(500))
        await connector.waitUntilStarted(addresses[2])
        await clock.advance(by: .milliseconds(500))
        await connector.waitUntilStarted(addresses[3])
        await clock.advance(by: .seconds(27))

        do {
            _ = try await task.value
            XCTFail("Expected the shared 30-second network deadline")
        } catch let error as HostAddressConnectionRaceError {
            guard case let .deadlineExceeded(outcomes) = error else {
                return XCTFail("Expected deadlineExceeded, got \(error)")
            }
            XCTAssertTrue(outcomes.allSatisfy { $0.outcome == .timedOut })
        }
        XCTAssertEqual(
            await connector.startedAddresses(),
            addresses,
            "The deadline is shared; it must not reset when a backup starts"
        )
    }

    func testNetworkWinnerClosesLosersAndOnlyWinnerCanProceed() async throws {
        let clock = Phase10TestClock()
        let connector = Phase10RaceConnector(clock: clock)
        let addresses = [
            HostAddress(address: "preferred.example.test"),
            HostAddress(address: "backup.example.test"),
        ]
        let task = Task {
            try await HostAddressConnectionRace.connect(
                addresses: addresses,
                policy: .default,
                clock: clock,
                using: connector.connect
            )
        }

        await connector.waitUntilStarted(addresses[0])
        await clock.advance(by: .seconds(2))
        await connector.waitUntilStarted(addresses[1])
        await connector.succeed(addresses[1])
        let result = try await task.value

        XCTAssertEqual(result.target, addresses[1])
        XCTAssertEqual(await connector.successfulConnectionCount(), 1)
        await connector.assertCancelled(addresses[0])
    }

    func testCancellingRaceRetiresAllCandidatesAndDoesNotPoisonRetry() async throws {
        let clock = Phase10TestClock()
        let connector = Phase10RaceConnector(clock: clock)
        let addresses = [
            HostAddress(address: "preferred.example.test"),
            HostAddress(address: "backup.example.test"),
        ]
        let first = Task {
            try await HostAddressConnectionRace.connect(
                addresses: addresses,
                policy: .default,
                clock: clock,
                using: connector.connect
            )
        }

        await connector.waitUntilStarted(addresses[0])
        await clock.advance(by: .seconds(2))
        await connector.waitUntilStarted(addresses[1])
        first.cancel()
        do {
            _ = try await first.value
            XCTFail("Expected cancellation to end the entire race")
        } catch is CancellationError {
            // Expected.
        }
        await connector.assertCancelled(addresses[0])
        await connector.assertCancelled(addresses[1])

        let retry = Task {
            try await HostAddressConnectionRace.connect(
                addresses: addresses,
                policy: .default,
                clock: clock,
                using: connector.connect
            )
        }
        await connector.waitUntilStarted(addresses[0], occurrence: 2)
        await connector.succeed(addresses[0], occurrence: 2)
        let retryResult = try await retry.value
        XCTAssertEqual(retryResult.target, addresses[0])
    }

    private func temporaryHostURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mudi-phase10-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("hosts.json")
    }
}

private actor Phase10TestClock: HostAddressRaceClock {
    private struct Waiter {
        let target: Duration
        let continuation: CheckedContinuation<Void, Error>
    }

    private var nowValue: Duration = .zero
    private var waiters: [UUID: Waiter] = [:]

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        let target = nowValue + duration
        if nowValue >= target {
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = Waiter(target: target, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func advance(by duration: Duration) {
        nowValue += duration
        let ready = waiters.filter { $0.value.target <= nowValue }
        for (id, waiter) in ready {
            waiters[id] = nil
            waiter.continuation.resume()
        }
    }

    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }
}

private actor Phase10RaceConnector {
    private enum State {
        case waiting(CheckedContinuation<any HostAddressNetworkConnection, Error>)
        case succeeded
        case failed(String)
    }

    private let clock: Phase10TestClock
    private var states: [HostAddress: [State]] = [:]
    private var starts: [(address: HostAddress, at: Duration)] = []
    private var cancellations: [HostAddress: Int] = [:]
    private var successes = 0

    init(clock: Phase10TestClock) {
        self.clock = clock
    }

    func connect(_ address: HostAddress) async throws -> any HostAddressNetworkConnection {
        starts.append((address, await clock.now()))
        let occurrence = states[address]?.count ?? 0
        if states[address] == nil { states[address] = [] }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                states[address, default: []].append(
                    .waiting(continuation)
                )
            }
        } onCancel: {
            Task { await self.cancel(address, occurrence: occurrence) }
        }
    }

    func waitUntilStarted(_ address: HostAddress, occurrence: Int = 1) async {
        while starts.filter({ $0.address == address }).count < occurrence {
            await Task.yield()
        }
    }

    func startedAddresses() -> [HostAddress] {
        starts.map(\.address)
    }

    func fail(_ address: HostAddress, message: String) {
        guard let index = states[address]?.firstIndex(where: {
            if case .waiting = $0 { return true }
            return false
        }) else { return }
        guard case let .waiting(continuation) = states[address]![index] else { return }
        states[address]![index] = .failed(message)
        continuation.resume(throwing: Phase10NetworkFailure(message: message))
    }

    func succeed(_ address: HostAddress, occurrence: Int = 1) {
        guard let index = states[address]?.firstIndex(where: {
            if case .waiting = $0 { return true }
            return false
        }) else { return }
        guard case let .waiting(continuation) = states[address]![index] else { return }
        states[address]![index] = .succeeded
        successes += 1
        continuation.resume(returning: Phase10RaceHandle(target: address))
    }

    func assertCancelled(_ address: HostAddress) async {
        for _ in 0..<100 where (cancellations[address] ?? 0) == 0 {
            await Task.yield()
        }
        XCTAssertGreaterThan(cancellations[address] ?? 0, 0, "Expected \(address) to be cancelled")
    }

    func successfulConnectionCount() -> Int {
        successes
    }

    private func cancel(_ address: HostAddress, occurrence: Int) {
        cancellations[address, default: 0] += 1
        guard let index = states[address]?.firstIndex(where: {
            if case .waiting = $0 { return true }
            return false
        }) else { return }
        guard case let .waiting(continuation) = states[address]![index] else { return }
        states[address]![index] = .failed("cancelled")
        continuation.resume(throwing: CancellationError())
    }

    func now() async -> Duration {
        await clock.now()
    }
}

private struct Phase10RaceHandle: HostAddressNetworkConnection {
    let target: HostAddress

    func close() async {}
}

private struct Phase10NetworkFailure: Error, LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

private extension Phase10TestClock {
    func now() -> Duration { nowValue }
}
