// swiftlint:disable file_length
import Foundation
import HerdrKit
import XCTest
@testable import Mudi

final class Phase10HostAddressTests: XCTestCase {  // pi-lens-ignore: type_body_length
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

    func testSSHConnectEndpointUsesSelectedAddressPortOverrideForTCPDial() {
        let host = Host(
            displayName: "Override Mac",
            addresses: [HostAddress(address: "tail.example.test", portOverride: 2200)],
            port: 22,
            username: "developer"
        )

        let endpoint = NIOSSHConnection.tcpEndpoint(for: host.targeting(host.addresses[0]))

        XCTAssertEqual(endpoint.hostname, "tail.example.test")
        XCTAssertEqual(endpoint.port, 2200)
    }

    func testAddressPromotionPreferenceDefaultsOffAndPersists() async throws {
        XCTAssertFalse(TerminalPreferences().isAddressPromotionEnabled)

        let oldJSON = """
        {
            "appearance": "system",
            "fontFamily": "JetBrainsMono Nerd Font Mono",
            "fontSize": 14
        }
        """.data(using: .utf8)!
        let decodedOld = try JSONDecoder().decode(TerminalPreferences.self, from: oldJSON)
        XCTAssertFalse(decodedOld.isAddressPromotionEnabled)

        let defaults = UserDefaults(suiteName: "mudi-phase10-\(UUID().uuidString)")!
        let store = UserDefaultsPreferencesStore(defaults: defaults, key: "preferences")
        var preferences = TerminalPreferences()
        preferences.isAddressPromotionEnabled = true
        try await store.save(preferences)

        let loaded = try await store.load()
        XCTAssertTrue(loaded.isAddressPromotionEnabled)
    }

    func testRootLoadsPersistedAddressPromotionIntoCoordinator() async throws {
        let store = Phase10MemoryPreferencesStore(
            TerminalPreferences(isAddressPromotionEnabled: true)
        )
        let application = ApplicationCoordinator(
            hostStore: Phase10MemoryHostStore(),
            credentialStore: Phase10MemoryCredentialStore(),
            knownHostKeyStore: Phase10MemoryKnownHostStore(),
            client: Phase10RecordingSSHClient(),
            moshTransport: Phase10NoopMoshTransport()
        )
        let model = await MainActor.run {
            RootViewModel(
                coordinator: application,
                preferencesStore: store
            )
        }

        await model.loadPreferences()

        let promotionEnabled = await application.isAddressPromotionEnabled()
        XCTAssertTrue(promotionEnabled)
    }

    func testAddressPromotionDefaultsToSavedOrder() async throws {
        let host = Host(
            displayName: "Manual Order Mac",
            addresses: [
                HostAddress(address: "lan.example.test"),
                HostAddress(address: "tailnet.example.test"),
            ],
            username: "developer"
        )
        let network = Phase10CoordinatorNetworkConnector(
            successfulAddresses: [host.addresses[1]]
        )
        let application = ApplicationCoordinator(
            hostStore: Phase10MemoryHostStore(),
            credentialStore: Phase10MemoryCredentialStore(),
            knownHostKeyStore: Phase10MemoryKnownHostStore(),
            client: Phase10RecordingSSHClient(),
            moshTransport: Phase10NoopMoshTransport(),
            networkConnector: network
        )

        _ = try await application.connect(
            to: host,
            credentials: SSHCredentials(password: "password"),
            hostKeyDecision: { _ in .accept }
        )

        let promotionEnabled = await application.isAddressPromotionEnabled()
        let networkTargets = await network.targets()
        XCTAssertFalse(promotionEnabled)
        XCTAssertEqual(
            networkTargets,
            [host.addresses[0], host.addresses[1]]
        )
    }

    func testAddressPromotionUsesLastSuccessWithoutRewritingOrderAndSkipsDeletedAddress() async throws {
        let host = Host(
            displayName: "Promoted Mac",
            addresses: [
                HostAddress(address: "lan.example.test"),
                HostAddress(address: "tailnet.example.test"),
            ],
            username: "developer"
        )
        let network = Phase10CoordinatorNetworkConnector(
            successfulAddresses: [host.addresses[1]]
        )
        let hostStore = Phase10MemoryHostStore()
        let credentialStore = Phase10MemoryCredentialStore()
        let client = Phase10RecordingSSHClient()
        let application = ApplicationCoordinator(
            hostStore: hostStore,
            credentialStore: credentialStore,
            knownHostKeyStore: Phase10MemoryKnownHostStore(),
            client: client,
            moshTransport: Phase10NoopMoshTransport(),
            networkConnector: network
        )
        try await hostStore.save(host)
        try await credentialStore.save(
            SSHCredentials(password: "password"),
            for: host
        )
        await application.setAddressPromotionEnabled(true)

        _ = try await application.connect(
            to: host,
            credentials: SSHCredentials(password: "password"),
            hostKeyDecision: { _ in .accept }
        )
        await application.disconnectAndWait()
        _ = try await application.reconnect(hostKeyDecision: { _ in .accept })
        await application.disconnectAndWait()

        let savedAfterPromotion = try await hostStore.loadHosts()
        XCTAssertEqual(savedAfterPromotion.first?.addresses, host.addresses)
        let networkTargets = await network.targets()
        XCTAssertEqual(
            networkTargets,
            [host.addresses[0], host.addresses[1], host.addresses[1]]
        )

        let deletedLastSuccess = Host(
            id: host.id,
            displayName: host.displayName,
            addresses: [host.addresses[0]],
            port: host.port,
            username: host.username,
            preferredTransport: host.preferredTransport
        )
        try await application.save(deletedLastSuccess)
        _ = try await application.reconnect(hostKeyDecision: { _ in .accept })

        let authenticatedHosts = await client.hosts()
        XCTAssertEqual(authenticatedHosts.last?.hostname, host.addresses[0].address)
        let savedAfterDeletion = try await hostStore.loadHosts()
        XCTAssertEqual(savedAfterDeletion.first?.addresses, [host.addresses[0]])
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
        let startsBeforeFailure = await connector.startedAddresses()
        XCTAssertEqual(startsBeforeFailure, [addresses[0]])

        await connector.fail(addresses[0], message: "unreachable")
        await connector.waitUntilStarted(addresses[1])
        let startsAfterFailure = await connector.startedAddresses()
        XCTAssertEqual(startsAfterFailure, [addresses[0], addresses[1]])

        await connector.succeed(addresses[1])
        let result = try await task.value
        XCTAssertEqual(result.target, addresses[1])
        let didStartThird = await connector.didStart(addresses[2])
        XCTAssertFalse(didStartThird)
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
        let startsAfterWindow = await connector.startedAddresses()
        XCTAssertEqual(startsAfterWindow, addresses)

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
        let startsAtDeadline = await connector.startedAddresses()
        XCTAssertEqual(startsAtDeadline, addresses)
    }

    func testDeadlineReturnsWithoutAwaitingUncooperativeConnectors() async throws {
        let clock = Phase10TestClock()
        let connector = Phase10UncooperativeRaceConnector()
        let addresses = [
            HostAddress(address: "stalled.example.test"),
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
        await clock.advance(by: .seconds(28))

        do {
            _ = try await task.value
            XCTFail("Expected the shared network deadline")
        } catch let error as HostAddressConnectionRaceError {
            guard case let .deadlineExceeded(outcomes) = error else {
                return XCTFail("Expected deadlineExceeded, got \(error)")
            }
            XCTAssertTrue(outcomes.allSatisfy { $0.outcome == .timedOut })
        }

        await connector.release(addresses[0])
        await connector.release(addresses[1])
    }

    func testDNSDelayConsumesTheSharedDeadlineAcrossCandidates() async throws {
        let clock = Phase10TestClock()
        let connector = Phase10DNSRaceConnector(clock: clock)
        let addresses = [
            HostAddress(address: "dns-one.example.test"),
            HostAddress(address: "dns-two.example.test"),
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
        await clock.advance(by: .seconds(28))

        do {
            _ = try await task.value
            XCTFail("Expected DNS/TCP deadline")
        } catch let error as HostAddressConnectionRaceError {
            guard case .deadlineExceeded = error else {
                return XCTFail("Expected deadlineExceeded, got \(error)")
            }
        }
        let startedAddresses = await connector.startedAddresses()
        XCTAssertEqual(startedAddresses, addresses)
    }

    func testNetworkWinnerClosesLosersAndReportsCancelledLosers() async throws {
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
        XCTAssertEqual(result.outcomes[0].outcome, .cancelled)
        XCTAssertEqual(result.outcomes[1].outcome, .succeeded)
        await connector.assertCancelled(addresses[0])
    }

    func testRaceReportsPreferredRacingAndSelectedProgress() async throws {
        let clock = Phase10TestClock()
        let connector = Phase10RaceConnector(clock: clock)
        let progress = Phase10ProgressRecorder()
        let addresses = [
            HostAddress(address: "preferred.example.test"),
            HostAddress(address: "backup.example.test"),
        ]
        let task = Task {
            try await HostAddressConnectionRace.connect(
                addresses: addresses,
                policy: .default,
                clock: clock,
                using: connector.connect,
                onProgress: { value in
                    await progress.record(value)
                }
            )
        }

        await connector.waitUntilStarted(addresses[0])
        await clock.advance(by: .seconds(2))
        await connector.waitUntilStarted(addresses[1])
        await connector.succeed(addresses[1])
        _ = try await task.value

        let events = await progress.values()
        XCTAssertTrue(events.contains {
            if case let .preferred(address, _) = $0 { return address == addresses[0] }
            return false
        })
        XCTAssertTrue(events.contains {
            if case let .racing(racingAddresses, _) = $0 {
                return racingAddresses == addresses
            }
            return false
        })
        XCTAssertTrue(events.contains {
            if case let .selected(address, _) = $0 { return address == addresses[1] }
            return false
        })
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
        let successfulConnections = await connector.successfulConnectionCount()
        XCTAssertEqual(successfulConnections, 1)
        await connector.assertCancelled(addresses[0])
    }

    func testCoordinatorAuthenticatesOnlyWinningAddressReusesWinnerAndPassesOverrideToSSH() async throws {
        let host = Host(
            displayName: "Multi-path Mac",
            addresses: [
                HostAddress(address: "preferred.example.test"),
                HostAddress(address: "tailnet.example.test", portOverride: 2200),
            ],
            port: 22,
            username: "developer",
            preferredTransport: .ssh
        )
        let network = Phase10CoordinatorNetworkConnector(
            successfulAddresses: [host.addresses[1]]
        )
        let client = Phase10RecordingSSHClient()
        let application = ApplicationCoordinator(
            hostStore: Phase10MemoryHostStore(),
            credentialStore: Phase10MemoryCredentialStore(),
            knownHostKeyStore: Phase10MemoryKnownHostStore(),
            client: client,
            moshTransport: Phase10NoopMoshTransport(),
            networkConnector: network
        )

        _ = try await application.connect(
            to: host,
            credentials: SSHCredentials(password: "password"),
            hostKeyDecision: { _ in .accept }
        )

        let networkTargets = await network.targets()
        XCTAssertEqual(networkTargets, [host.addresses[0], host.addresses[1]])
        let handoffTargets = await client.handoffTargets()
        XCTAssertEqual(handoffTargets, [host.addresses[1]])
        let authenticatedHosts = await client.hosts()
        XCTAssertEqual(authenticatedHosts.count, 1)
        XCTAssertEqual(authenticatedHosts[0].id, host.id)
        XCTAssertEqual(authenticatedHosts[0].hostname, host.addresses[1].address)
        XCTAssertEqual(authenticatedHosts[0].effectivePort, 2200)
        let closeCount = await network.closeCount()
        XCTAssertEqual(closeCount, 0)
    }

    func testAuthenticationFailureDoesNotFallBackToAnotherAddress() async throws {
        let host = Host(
            displayName: "Changed-key Mac",
            addresses: [
                HostAddress(address: "lan.example.test"),
                HostAddress(address: "tailnet.example.test"),
                HostAddress(address: "public.example.test"),
            ],
            port: 22,
            username: "developer",
            preferredTransport: .ssh
        )
        let network = Phase10CoordinatorNetworkConnector(
            successfulAddresses: [host.addresses[1], host.addresses[2]]
        )
        let client = Phase10RecordingSSHClient(
            authenticationError: .hostKeyMismatch(
                expected: "SHA256:trusted",
                actual: "SHA256:changed"
            )
        )
        let application = ApplicationCoordinator(
            hostStore: Phase10MemoryHostStore(),
            credentialStore: Phase10MemoryCredentialStore(),
            knownHostKeyStore: Phase10MemoryKnownHostStore(),
            client: client,
            moshTransport: Phase10NoopMoshTransport(),
            networkConnector: network
        )

        do {
            _ = try await application.connect(
                to: host,
                credentials: SSHCredentials(password: "password"),
                hostKeyDecision: { _ in .accept }
            )
            XCTFail("A host-key mismatch must fail the selected target")
        } catch let error as ConnectionError {
            XCTAssertEqual(
                error,
                .hostKeyMismatch(expected: "SHA256:trusted", actual: "SHA256:changed")
            )
        }

        let authenticatedHosts = await client.hosts()
        let handoffTargets = await client.handoffTargets()
        let networkTargets = await network.targets()
        XCTAssertEqual(authenticatedHosts.count, 1)
        XCTAssertEqual(authenticatedHosts[0].selectedTarget, host.addresses[1])
        XCTAssertEqual(handoffTargets, [host.addresses[1]])
        XCTAssertEqual(networkTargets, [host.addresses[0], host.addresses[1]])
    }

    func testReconnectRetainsTheActualWinningAddressInsteadOfUsingListHead() async throws {
        let host = Host(
            displayName: "Reconnect Mac",
            addresses: [
                HostAddress(address: "preferred.example.test"),
                HostAddress(address: "tailnet.example.test"),
            ],
            port: 22,
            username: "developer",
            preferredTransport: .ssh
        )
        let network = Phase10CoordinatorNetworkConnector(
            successfulAddresses: [host.addresses[1]]
        )
        let client = Phase10RecordingSSHClient()
        let hostStore = Phase10MemoryHostStore()
        let credentialStore = Phase10MemoryCredentialStore()
        let application = ApplicationCoordinator(
            hostStore: hostStore,
            credentialStore: credentialStore,
            knownHostKeyStore: Phase10MemoryKnownHostStore(),
            client: client,
            moshTransport: Phase10NoopMoshTransport(),
            networkConnector: network
        )
        try await hostStore.save(host)
        try await credentialStore.save(
            SSHCredentials(password: "password"),
            for: host
        )

        _ = try await application.connect(
            to: host,
            credentials: SSHCredentials(password: "password"),
            hostKeyDecision: { _ in .accept }
        )
        await application.disconnectAndWait()
        _ = try await application.reconnect(hostKeyDecision: { _ in .accept })

        let targets = await network.targets()
        XCTAssertEqual(targets, [host.addresses[0], host.addresses[1], host.addresses[1]])
        let authenticatedHosts = await client.hosts()
        XCTAssertEqual(authenticatedHosts.last?.hostname, host.addresses[1].address)
    }

    func testMoshReceivesTheSameSelectedAddressAsSSHBootstrap() async throws {
        let host = Host(
            displayName: "Mosh Mac",
            addresses: [HostAddress(address: "tailnet.example.test", portOverride: 2222)],
            port: 22,
            username: "developer",
            preferredTransport: .mosh
        )
        let network = Phase10CoordinatorNetworkConnector(
            successfulAddresses: [host.addresses[0]]
        )
        let client = Phase10RecordingSSHClient()
        let mosh = Phase10RecordingMoshTransport()
        let application = ApplicationCoordinator(
            hostStore: Phase10MemoryHostStore(),
            credentialStore: Phase10MemoryCredentialStore(),
            knownHostKeyStore: Phase10MemoryKnownHostStore(),
            client: client,
            moshTransport: mosh,
            networkConnector: network
        )

        _ = try await application.connect(
            to: host,
            credentials: SSHCredentials(password: "password"),
            hostKeyDecision: { _ in .accept }
        )

        let moshHosts = await mosh.hosts()
        XCTAssertEqual(moshHosts.count, 1)
        XCTAssertEqual(moshHosts[0].hostname, host.addresses[0].address)
        XCTAssertEqual(moshHosts[0].effectivePort, 2222)
        let activeHost = await application.activeHost()
        XCTAssertEqual(activeHost?.hostname, host.addresses[0].address)
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
        first.cancel()
        do {
            _ = try await first.value
            XCTFail("Expected cancellation to end the entire race")
        } catch is CancellationError {
            // Expected.
        }
        await connector.assertCancelled(addresses[0])
        let startedBackup = await connector.didStart(addresses[1])
        XCTAssertFalse(startedBackup)

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

private actor Phase10UncooperativeRaceConnector {
    private var starts: [HostAddress] = []
    private var waiters: [HostAddress: CheckedContinuation<any HostAddressNetworkConnection, Error>] = [:]

    func connect(_ address: HostAddress) async throws -> any HostAddressNetworkConnection {
        starts.append(address)
        return try await withCheckedThrowingContinuation { continuation in
            waiters[address] = continuation
        }
    }

    func waitUntilStarted(_ address: HostAddress) async {
        while !starts.contains(address) {
            await Task.yield()
        }
    }

    func release(_ address: HostAddress) {
        waiters.removeValue(forKey: address)?.resume(
            returning: Phase10RaceHandle(target: address)
        )
    }
}

private actor Phase10DNSRaceConnector {
    private let clock: Phase10TestClock
    private var starts: [HostAddress] = []

    init(clock: Phase10TestClock) {
        self.clock = clock
    }

    func connect(_ address: HostAddress) async throws -> any HostAddressNetworkConnection {
        starts.append(address)
        try await clock.sleep(for: .seconds(60))
        return Phase10RaceHandle(target: address)
    }

    func waitUntilStarted(_ address: HostAddress) async {
        while !starts.contains(address) {
            await Task.yield()
        }
    }

    func startedAddresses() -> [HostAddress] { starts }
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

    func didStart(_ address: HostAddress) -> Bool {
        starts.contains { $0.address == address }
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

private actor Phase10ProgressRecorder {
    private var recorded: [HostAddressRaceProgress] = []

    func record(_ progress: HostAddressRaceProgress) {
        recorded.append(progress)
    }

    func values() -> [HostAddressRaceProgress] { recorded }
}

private actor Phase10MemoryPreferencesStore: PreferencesStore {
    private var value: TerminalPreferences

    init(_ value: TerminalPreferences = TerminalPreferences()) {
        self.value = value
    }

    func load() async throws -> TerminalPreferences { value }

    func save(_ preferences: TerminalPreferences) async throws {
        value = preferences
    }
}

private actor Phase10MemoryHostStore: HostStore {
    private var values: [Host] = []

    func loadHosts() async throws -> [Host] { values }
    func save(_ host: Host) async throws {
        if let index = values.firstIndex(where: { $0.id == host.id }) {
            values[index] = host
        } else {
            values.append(host)
        }
    }
    func delete(_ host: Host) async throws {
        values.removeAll { $0.id == host.id }
    }
}

private actor Phase10MemoryCredentialStore: CredentialStore {
    private var values: [Host.ID: SSHCredentials] = [:]

    func save(_ credentials: SSHCredentials, for host: Host) async throws {
        values[host.id] = credentials
    }
    func credentials(for host: Host) async throws -> SSHCredentials? {
        values[host.id]
    }
    func delete(for host: Host) async throws {
        values[host.id] = nil
    }
}

private actor Phase10MemoryKnownHostStore: KnownHostKeyStore {
    private var values: [Host.ID: String] = [:]

    func remember(_ fingerprint: String, for host: Host) async throws {
        values[host.id] = fingerprint
    }
    func fingerprint(for host: Host) async throws -> String? {
        values[host.id]
    }
    func delete(for host: Host) async throws {
        values[host.id] = nil
    }
}

private actor Phase10CoordinatorNetworkConnector: HostAddressNetworkConnecting {
    private let successfulAddresses: Set<HostAddress>
    private var targetValues: [HostAddress] = []
    private var closeCountValue = 0

    init(successfulAddresses: [HostAddress]) {
        self.successfulAddresses = Set(successfulAddresses)
    }

    func connectNetwork(to host: Host) async throws -> any HostAddressNetworkConnection {
        let target = host.selectedTarget ?? host.addresses.first!
        targetValues.append(target)
        guard successfulAddresses.contains(target) else {
            throw Phase10NetworkFailure(message: "network unavailable")
        }
        return Phase10CoordinatorNetworkHandle(
            target: target,
            onClose: { [weak self] in
                await self?.recordClose()
            }
        )
    }

    func targets() -> [HostAddress] { targetValues }
    func closeCount() -> Int { closeCountValue }

    private func recordClose() {
        closeCountValue += 1
    }
}

private struct Phase10CoordinatorNetworkHandle: HostAddressNetworkConnection {
    let target: HostAddress
    let onClose: @Sendable () async -> Void

    func close() async {
        await onClose()
    }
}

private actor Phase10RecordingSSHClient: HostKeyAwareSSHClient,
    HostAddressNetworkHandoff
{
    private let authenticationError: ConnectionError?
    private var hostValues: [Host] = []
    private var handoffValues: [HostAddress] = []

    init(authenticationError: ConnectionError? = nil) {
        self.authenticationError = authenticationError
    }

    func connect(
        to host: Host,
        credentials: SSHCredentials,
        hostKeyDecision: @escaping @Sendable (String) async -> HostKeyDecision
    ) async throws -> any PTYChannel {
        try await authenticate(
            to: host,
            credentials: credentials,
            hostKeyDecision: hostKeyDecision
        )
    }

    func connect(
        to host: Host,
        credentials: SSHCredentials,
        hostKeyDecision: @escaping @Sendable (String) async -> HostKeyDecision,
        using networkConnection: any HostAddressNetworkConnection
    ) async throws -> any PTYChannel {
        handoffValues.append(networkConnection.target)
        return try await authenticate(
            to: host,
            credentials: credentials,
            hostKeyDecision: hostKeyDecision
        )
    }

    func hosts() -> [Host] { hostValues }
    func handoffTargets() -> [HostAddress] { handoffValues }

    private func authenticate(
        to host: Host,
        credentials _: SSHCredentials,
        hostKeyDecision: @escaping @Sendable (String) async -> HostKeyDecision
    ) async throws -> any PTYChannel {
        hostValues.append(host)
        if let authenticationError {
            throw authenticationError
        }
        guard await hostKeyDecision("SHA256:phase10") == .accept else {
            throw ConnectionError.hostKeyRejected
        }
        return Phase10CoordinatorPTY()
    }
}

private struct Phase10CoordinatorPTY: PTYChannel {
    func send(_: [UInt8]) async throws {}
    func resize(columns _: Int, rows _: Int) async throws {}
    func close() async {}
}

private struct Phase10NoopMoshTransport: MoshTransportBootstrapping {
    func connect(
        to _: Host,
        credentials _: SSHCredentials,
        using _: SSHShellSession
    ) async throws -> SSHShellSession {
        SSHShellSession(connectedChannel: Phase10CoordinatorPTY())
    }
    func disconnect() async {}
}

private actor Phase10RecordingMoshTransport: MoshTransportBootstrapping {
    private var hostValues: [Host] = []

    func connect(
        to host: Host,
        credentials _: SSHCredentials,
        using _: SSHShellSession
    ) async throws -> SSHShellSession {
        hostValues.append(host)
        return SSHShellSession(connectedChannel: Phase10CoordinatorPTY())
    }
    func disconnect() async {}
    func hosts() -> [Host] { hostValues }
}

private struct Phase10NetworkFailure: Error, LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

private extension Phase10TestClock {
    func now() -> Duration { nowValue }
}
