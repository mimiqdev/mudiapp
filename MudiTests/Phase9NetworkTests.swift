import Foundation
import HerdrKit
@preconcurrency import TraversioMoshBootstrap
@preconcurrency import TraversioMoshCore
import XCTest
@testable import Mudi

@MainActor
final class Phase9NetworkTests: XCTestCase {  // pi-lens-ignore: type_body_length
    // MARK: Address-family policy

    func testIPv6OnlyAddressListUsesOneIPv6Attempt() async throws {
        let address = Phase9ResolvedAddress(
            "2001:db8::44",
            family: .ipv6
        )
        let policy = Phase9ConnectionPolicy.documentedDefault
        let connector = Phase9RecordingAddressConnector(
            outcomes: [address.value: .success]
        )

        let plan = policy.attemptPlan(for: [address])
        XCTAssertEqual(plan.map(\.address), [address])
        XCTAssertEqual(plan.map(\.startAfter), [.zero])

        let selected = try await MissingPhase9ConnectionStrategy.connect(
            to: [address],
            policy: policy,
            using: connector
        )
        XCTAssertEqual(selected, address)
        let records = await connector.attemptRecords()
        XCTAssertEqual(records.map(\.address.family), [.ipv6])
    }

    func testIPv4OnlyAddressListUsesOneIPv4Attempt() async throws {
        let address = Phase9ResolvedAddress(
            "192.0.2.44",
            family: .ipv4
        )
        let policy = Phase9ConnectionPolicy.documentedDefault
        let connector = Phase9RecordingAddressConnector(
            outcomes: [address.value: .success]
        )

        let plan = policy.attemptPlan(for: [address])
        XCTAssertEqual(plan.map(\.address), [address])
        XCTAssertEqual(plan.map(\.startAfter), [.zero])

        let selected = try await MissingPhase9ConnectionStrategy.connect(
            to: [address],
            policy: policy,
            using: connector
        )
        XCTAssertEqual(selected, address)
        let records = await connector.attemptRecords()
        XCTAssertEqual(records.map(\.address.family), [.ipv4])
    }

    func testDualStackStartsAlternateFamilyBeforeFirstAttemptTimeout() async throws {
        let ipv6 = Phase9ResolvedAddress(
            "2001:db8::44",
            family: .ipv6
        )
        let ipv4 = Phase9ResolvedAddress(
            "192.0.2.44",
            family: .ipv4
        )
        let policy = Phase9ConnectionPolicy.documentedDefault
        let connector = Phase9BlockingAddressConnector(
            blockingAddress: ipv6,
            outcomes: [
                ipv6.value: .failure(.timedOut),
                ipv4.value: .success,
            ]
        )

        let plan = policy.attemptPlan(for: [ipv6, ipv4])
        XCTAssertEqual(
            plan.map(\.address.family),
            [.ipv6, .ipv4],
            "The alternate address family must be attempted, not discarded"
        )
        XCTAssertEqual(
            plan.map(\.startAfter),
            [.zero, .milliseconds(250)],
            "Happy Eyeballs must stagger the alternate family"
        )
        XCTAssertEqual(
            plan.map(\.timeout),
            [.seconds(60), .seconds(60)],
            "Each address gets the configured per-attempt timeout"
        )

        let connectionTask = Task<Phase9ResolvedAddress?, Never> {
            try? await MissingPhase9ConnectionStrategy.connect(
                to: [ipv6, ipv4],
                policy: policy,
                using: connector
            )
        }
        await connector.waitUntilStarted(ipv6)
        let alternateStarted = await waitForAttemptStart(
            ipv4,
            connector: connector
        )
        XCTAssertTrue(
            alternateStarted,
            "The alternate family must start while the first connect is blocked"
        )

        await connector.releaseBlockingAttempt()
        let selected = await connectionTask.value
        XCTAssertEqual(selected, ipv4)
        let records = await connector.attemptRecords()
        XCTAssertEqual(records.map(\.address.family), [.ipv6, .ipv4])
        XCTAssertEqual(
            records.map(\.startAfter),
            [.zero, .milliseconds(250)]
        )
        assertStaggeredStart(
            first: records[0].startedAt,
            second: records[1].startedAt,
            stagger: policy.addressFamilyStagger
        )
    }

    func testDualStackFallbackDoesNotWaitForDeadFamilyTimeout() async throws {
        let ipv4 = Phase9ResolvedAddress(
            "192.0.2.44",
            family: .ipv4
        )
        let ipv6 = Phase9ResolvedAddress(
            "2001:db8::44",
            family: .ipv6
        )
        let policy = Phase9ConnectionPolicy.documentedDefault
        let connector = Phase9BlockingAddressConnector(
            blockingAddress: ipv4,
            outcomes: [
                ipv4.value: .failure(.unreachable),
                ipv6.value: .success,
            ]
        )

        let connectionTask = Task<Phase9ResolvedAddress?, Never> {
            try? await MissingPhase9ConnectionStrategy.connect(
                to: [ipv4, ipv6],
                policy: policy,
                using: connector
            )
        }
        await connector.waitUntilStarted(ipv4)
        let alternateStarted = await waitForAttemptStart(
            ipv6,
            connector: connector
        )
        XCTAssertTrue(
            alternateStarted,
            "IPv6 must start before the dead IPv4 attempt returns or times out"
        )

        await connector.releaseBlockingAttempt()
        let selected = await connectionTask.value
        XCTAssertEqual(selected, ipv6)

        let records = await connector.attemptRecords()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[1].startAfter, .milliseconds(250))
        XCTAssertLessThan(
            records[1].startAfter,
            policy.perAttemptTimeout,
            "IPv6 must start before the dead IPv4 attempt exhausts its timeout"
        )
        assertStaggeredStart(
            first: records[0].startedAt,
            second: records[1].startedAt,
            stagger: policy.addressFamilyStagger
        )
    }

    // MARK: Connect timeout

    func testNIOSSHConnectionConnectPathUsesCellularTailnetBudget() {
        XCTAssertEqual(
            NIOSSHConnection.connectTimeout,
            .seconds(60),
            "The production ClientBootstrap connect timeout must cover tailnets"
        )
    }

    func testCellularTailnetConnectTimeoutHasPinnedDocumentedDefault() {
        let policy = Phase9ConnectionPolicy.documentedDefault
        let documentation = policy.documentation.lowercased()

        XCTAssertEqual(
            policy.perAttemptTimeout,
            .seconds(60),
            "The default must not regress to a LAN-only connect budget"
        )
        XCTAssertEqual(policy.addressFamilyStagger, .milliseconds(250))
        XCTAssertTrue(documentation.contains("cellular"))
        XCTAssertTrue(
            documentation.contains("vpn") || documentation.contains("tailnet"),
            "The timeout rationale must document cellular/VPN use"
        )
    }

    func testConfigurableConnectTimeoutIsForwardedToEveryAttempt() async throws {
        let addresses = [
            Phase9ResolvedAddress("2001:db8::44", family: .ipv6),
            Phase9ResolvedAddress("192.0.2.44", family: .ipv4),
        ]
        let policy = Phase9ConnectionPolicy(
            addressFamilyStagger: .milliseconds(125),
            perAttemptTimeout: .seconds(75),
            documentation: "A test-specific cellular/VPN budget."
        )
        let connector = Phase9RecordingAddressConnector(
            outcomes: [
                addresses[0].value: .failure(.timedOut),
                addresses[1].value: .success,
            ]
        )

        _ = try await MissingPhase9ConnectionStrategy.connect(
            to: addresses,
            policy: policy,
            using: connector
        )

        let records = await connector.attemptRecords()
        XCTAssertEqual(records.map(\.timeout), [.seconds(75), .seconds(75)])
    }

    func testSlowCellularConnectIsNotCancelledBeforeConfiguredTimeout() async {
        let address = Phase9ResolvedAddress(
            "100.64.0.44",
            family: .ipv4
        )
        let connector = Phase9SlowAddressConnector(
            successfulAfter: .seconds(45)
        )

        do {
            let selected = try await MissingPhase9ConnectionStrategy.connect(
                to: [address],
                policy: .documentedDefault,
                using: connector
            )
            XCTAssertEqual(selected, address)
        } catch {
            XCTFail(
                "A 45-second cellular/VPN handshake must fit the default: \(error)"
            )
        }
    }

    // MARK: Auto transport fallback

    func testAutomaticTransportFallsBackToSSHForEveryMoshFailureClass() async throws {
        let failures: [Phase9MoshFailureClass] = [
            .udpTimedOut,
            .udpBlockedOnTailnetOrCarrier,
            .moshServerUnavailable,
        ]

        for failure in failures {
            let recorder = Phase9MoshAttemptRecorder()
            let application = makeMissingPhase2Application(
                client: Phase2SSHClient(
                    presentedFingerprint: "SHA256:phase9-\(failure)"
                ),
                moshTransport: Phase9MoshFailureTransport(
                    failure: failure,
                    recorder: recorder
                )
            )
            let host = phase9Host(preferredTransport: .automatic)

            do {
                let state = try await application.connect(
                    to: host,
                    credentials: phase2Credentials(),
                    hostKeyDecision: { _ in .accept }
                )
                XCTAssertEqual(state, .connected)
                let activeTransport = await application.activeTransport()
                XCTAssertEqual(activeTransport, .ssh)
            } catch {
                XCTFail(
                    "Auto must keep SSH usable after \(failure): \(error)"
                )
            }

            let recordedFailures = await recorder.recordedFailures()
            XCTAssertEqual(recordedFailures, [failure])
            let classified = await application.lastAutomaticMoshFailureClass()
            XCTAssertEqual(classified, failure)
        }
    }

    func testAutomaticFallbackClassifiesConcreteAdapterErrors() async throws {
        let cases: [(any Error, Phase9MoshFailureClass)] = [
            (MoshFirstContactError.timedOut, .udpTimedOut),
            (MoshBootstrapParseError.connectLineNotFound, .moshServerUnavailable),
            (MoshSessionError.linkRebuildAttemptsExhausted, .udpTimedOut),
            (MoshBootstrapParseError.malformedConnectLine, .moshServerUnavailable),
            (
                SSHInteractiveCommandError.commandFailed(
                    exitCode: 127,
                    message: "mosh-server: command not found"
                ),
                .moshServerUnavailable
            ),
        ]

        for (error, expected) in cases {
            let recorder = Phase9MoshAttemptRecorder()
            let selection = try await TransportSelectionStrategy.select(
                preference: .automatic,
                bootstrapSSH: {},
                connectMosh: { () async throws -> SSHShellSession in
                    throw error
                },
                onMoshFailure: { classifiedFailure in
                    await recorder.record(classifiedFailure)
                }
            )
            XCTAssertEqual(selection.transport, .ssh)
            let recordedClasses = await recorder.recordedFailures()
            XCTAssertEqual(
                recordedClasses,
                [expected],
                "Adapter error \(error) must classify as \(expected)"
            )

            let application = makeMissingPhase2Application(
                client: Phase2SSHClient(
                    presentedFingerprint: "SHA256:phase9-adapter-\(expected)"
                ),
                moshTransport: Phase9ThrowingMoshTransport(error: error)
            )
            let state = try await application.connect(
                to: phase9Host(preferredTransport: .automatic),
                credentials: phase2Credentials(),
                hostKeyDecision: { _ in .accept }
            )
            XCTAssertEqual(state, .connected)
            let classified = await application.lastAutomaticMoshFailureClass()
            XCTAssertEqual(classified, expected)
            let activeTransport = await application.activeTransport()
            XCTAssertEqual(activeTransport, .ssh)
        }
    }

    func testAutomaticFallbackClassifiesEveryMoshFailureAsSSHFallback()
        async throws
    {
        let failures: [Phase9MoshFailureClass] = [
            .udpTimedOut,
            .udpBlockedOnTailnetOrCarrier,
            .moshServerUnavailable,
        ]

        for failure in failures {
            let recorder = Phase9MoshAttemptRecorder()
            let selection = try await TransportSelectionStrategy.select(
                preference: .automatic,
                bootstrapSSH: {},
                connectMosh: { () async throws -> SSHShellSession in
                    throw failure
                },
                onMoshFailure: { classifiedFailure in
                    await recorder.record(classifiedFailure)
                }
            )
            XCTAssertEqual(selection.transport, .ssh)
            let recordedClasses = await recorder.recordedFailures()
            XCTAssertEqual(
                recordedClasses,
                [failure],
                "Auto must preserve the production failure class for \(failure)"
            )
        }

        let blocked = Phase9MoshFailureClass.udpBlockedOnTailnetOrCarrier
        XCTAssertFalse(
            blocked.localizedDescription.localizedCaseInsensitiveContains(
                "timed out"
            ),
            "UDP blocking must not be presented as only a timeout"
        )
    }

    // MARK: Transparent reconnect

    func testNetworkPathChangeWhileMountedStartsReconnectWithoutSceneActivation()
        async throws
    {
        let fixture = try Phase3HerdrFixtures.single()
        let reconnectGate = Phase2ConnectionGate()
        let pathMonitor = Phase9NetworkPathMonitor()
        let client = Phase2SSHClient(
            presentedFingerprint: "SHA256:phase4-test-key",
            reconnectGate: reconnectGate
        )
        let application = makePhase4NavigationApplication(
            fixture: fixture,
            client: client,
            networkPathMonitor: pathMonitor
        )
        let host = phase4Host()
        try await application.save(host)

        application.model.connect(to: host)
        try await waitUntil { application.model.activeConnection != nil }
        application.model.selectOrdinaryTerminalFromPicker()
        try await waitUntil { application.model.herdrState == .ordinaryTerminal }
        let oldSession = try XCTUnwrap(
            application.model.activeConnection?.session
        )

        pathMonitor.emit(
            NetworkPathSnapshot(
                status: .satisfied,
                interfaces: [.cellular],
                isExpensive: true,
                isConstrained: false
            )
        )
        pathMonitor.emit(
            NetworkPathSnapshot(
                status: .satisfied,
                interfaces: [.wifi],
                isExpensive: false,
                isConstrained: false
            )
        )

        try await waitUntil { application.model.isTransparentlyReconnecting }
        XCTAssertFalse(application.model.isSceneInactive)
        XCTAssertIdentical(
            application.model.activeConnection?.session,
            oldSession,
            "A path-change reconnect must keep the mounted terminal in place"
        )

        await reconnectGate.release()
        try await waitUntil {
            !application.model.isTransparentlyReconnecting
                && application.model.activeConnection?.session !== oldSession
        }
        XCTAssertNil(application.model.errorMessage)
        XCTAssertEqual(application.model.activeTransport, .ssh)
    }

    func testUnsatisfiedPathWaitsForSatisfactionBeforeRetakingPane()
        async throws
    {
        let fixture = try Phase3HerdrFixtures.single()
        let pane = try XCTUnwrap(phase4Panes(in: fixture).first)
        let reconnectGate = Phase2ConnectionGate()
        let pathMonitor = Phase9NetworkPathMonitor()
        let client = Phase2SSHClient(
            presentedFingerprint: "SHA256:phase4-test-key",
            reconnectGate: reconnectGate
        )
        let application = makePhase4NavigationApplication(
            fixture: fixture,
            client: client,
            networkPathMonitor: pathMonitor
        )
        let host = phase4Host()
        try await application.save(host)

        application.model.connect(to: host)
        try await waitUntil { application.model.activeConnection != nil }
        application.model.selectPane(pane.id)
        try await waitUntil {
            if case .attached = application.model.herdrState { return true }
            return false
        }
        let oldSession = try XCTUnwrap(
            application.model.activeConnection?.session
        )

        let satisfiedWiFi = NetworkPathSnapshot(
            status: .satisfied,
            interfaces: [.wifi],
            isExpensive: false,
            isConstrained: false
        )
        let unsatisfied = NetworkPathSnapshot(
            status: .unsatisfied,
            interfaces: [],
            isExpensive: false,
            isConstrained: false
        )
        pathMonitor.emit(satisfiedWiFi)
        try await waitUntil {
            application.model.networkPathRecovery.lastPath == satisfiedWiFi
        }
        pathMonitor.emit(unsatisfied)
        try await waitUntil {
            application.model.networkPathRecovery.lastPath == unsatisfied
        }

        try await Task.sleep(for: .milliseconds(350))
        XCTAssertFalse(
            application.model.isTransparentlyReconnecting,
            "An unsatisfied path must not start a reconnect"
        )
        XCTAssertNotNil(
            application.model.activeConnection,
            "The terminal must stay mounted while the path is unavailable"
        )
        XCTAssertTrue(application.model.networkPathRecovery.changePending)
        guard case .attached = application.model.herdrState else {
            return XCTFail(
                "An unsatisfied path must not return the user to Hosts"
            )
        }
        XCTAssertNil(application.model.errorMessage)

        let satisfiedCellular = NetworkPathSnapshot(
            status: .satisfied,
            interfaces: [.cellular],
            isExpensive: true,
            isConstrained: false
        )
        pathMonitor.emit(satisfiedCellular)
        try await waitUntil {
            application.model.isTransparentlyReconnecting
        }
        XCTAssertIdentical(
            application.model.activeConnection?.session,
            oldSession,
            "The pane must remain mounted during recovery"
        )

        await reconnectGate.release()
        try await waitUntil {
            !application.model.isTransparentlyReconnecting
                && application.model.activeConnection?.session !== oldSession
        }
        guard case .attached(_, let retakenPane) = application.model.herdrState
        else {
            return XCTFail("The satisfied path must retake the pane")
        }
        XCTAssertEqual(retakenPane.id, pane.id)
        XCTAssertFalse(application.model.isPanePickerPresented)
        XCTAssertNil(application.model.errorMessage)
    }

    func testReturnToHostsCancelsPathChangeReconnectAndClearsOverlay()
        async throws
    {
        let fixture = try Phase3HerdrFixtures.single()
        let reconnectGate = Phase2ConnectionGate()
        let pathMonitor = Phase9NetworkPathMonitor()
        let client = Phase2SSHClient(
            presentedFingerprint: "SHA256:phase4-test-key",
            reconnectGate: reconnectGate
        )
        let application = makePhase4NavigationApplication(
            fixture: fixture,
            client: client,
            networkPathMonitor: pathMonitor
        )
        let host = phase4Host()
        try await application.save(host)

        application.model.connect(to: host)
        try await waitUntil { application.model.activeConnection != nil }
        application.model.selectOrdinaryTerminalFromPicker()
        try await waitUntil { application.model.herdrState == .ordinaryTerminal }
        pathMonitor.emit(
            NetworkPathSnapshot(
                status: .satisfied,
                interfaces: [.wifi],
                isExpensive: false,
                isConstrained: false
            )
        )
        pathMonitor.emit(
            NetworkPathSnapshot(
                status: .satisfied,
                interfaces: [.cellular],
                isExpensive: true,
                isConstrained: false
            )
        )
        try await waitUntil { application.model.isTransparentlyReconnecting }

        application.model.returnToHosts()
        XCTAssertFalse(
            application.model.isTransparentlyReconnecting,
            "Leaving the terminal must clear the overlay synchronously"
        )
        XCTAssertNil(application.model.activeConnection)

        await reconnectGate.release()
        try await waitUntil { !application.model.isTearingDown }
        XCTAssertFalse(application.model.isTransparentlyReconnecting)
    }

    func testPathChangeReconnectIsBoundedByConfiguredConnectTimeout()
        async throws
    {
        let fixture = try Phase3HerdrFixtures.single()
        let reconnectGate = Phase2ConnectionGate()
        let pathMonitor = Phase9NetworkPathMonitor()
        let client = Phase2SSHClient(
            presentedFingerprint: "SHA256:phase4-test-key",
            reconnectGate: reconnectGate
        )
        let application = makePhase4NavigationApplication(
            fixture: fixture,
            client: client,
            networkPathMonitor: pathMonitor,
            reconnectTimeout: .milliseconds(100)
        )
        let host = phase4Host()
        try await application.save(host)

        application.model.connect(to: host)
        try await waitUntil { application.model.activeConnection != nil }
        application.model.selectOrdinaryTerminalFromPicker()
        try await waitUntil { application.model.herdrState == .ordinaryTerminal }
        pathMonitor.emit(
            NetworkPathSnapshot(
                status: .satisfied,
                interfaces: [.wifi],
                isExpensive: false,
                isConstrained: false
            )
        )
        pathMonitor.emit(
            NetworkPathSnapshot(
                status: .satisfied,
                interfaces: [.cellular],
                isExpensive: true,
                isConstrained: false
            )
        )
        try await waitUntil { application.model.isTransparentlyReconnecting }

        try await waitUntil({
            !application.model.isTransparentlyReconnecting
        }, timeoutSeconds: 1)
        XCTAssertNil(application.model.activeConnection)
        XCTAssertEqual(
            application.model.errorMessage,
            RootViewModel.transparentReconnectFailureMessage
        )
        await reconnectGate.release()
    }

    func testTransportDisconnectOnSceneResumeKeepsTerminalMountedAndReconnectsOnce()
        async throws
    {
        let fixture = try Phase3HerdrFixtures.single()
        let reconnectGate = Phase2ConnectionGate()
        let client = Phase2SSHClient(
            presentedFingerprint: "SHA256:phase4-test-key",
            reconnectGate: reconnectGate
        )
        let application = makePhase4NavigationApplication(
            fixture: fixture,
            client: client
        )
        let host = phase4Host()
        try await application.save(host)

        application.model.connect(to: host)
        try await waitUntil { application.model.activeConnection != nil }
        application.model.selectOrdinaryTerminalFromPicker()
        try await waitUntil { application.model.herdrState == .ordinaryTerminal }
        let oldSession = try XCTUnwrap(
            application.model.activeConnection?.session
        )

        application.model.sceneWillResignActive()
        await application.model.sceneDidEnterBackground()
        await application.transport.simulateBaseSessionDeath()
        await application.transport.disconnect()
        await application.model.handleTerminalSessionClosed(
            for: ObjectIdentifier(oldSession)
        )

        XCTAssertIdentical(application.model.activeConnection?.session, oldSession)
        let activationTask = Task {
            await application.model.sceneDidBecomeActive()
        }
        await reconnectGate.waitUntilStarted()

        XCTAssertTrue(application.model.isTransparentlyReconnecting)
        XCTAssertIdentical(
            application.model.activeConnection?.session,
            oldSession,
            "The dead terminal remains mounted while recovery is in flight"
        )
        XCTAssertEqual(application.model.herdrState, .ordinaryTerminal)

        await reconnectGate.release()
        await activationTask.value

        XCTAssertNotIdentical(
            application.model.activeConnection?.session,
            oldSession
        )
        XCTAssertEqual(application.model.transparentReconnectAttemptsUsed, 1)
        XCTAssertFalse(application.model.isTransparentlyReconnecting)
        XCTAssertNil(application.model.errorMessage)
        let connectionAttempts = await client.connectionAttempts()
        XCTAssertEqual(connectionAttempts, 2)
    }

    func testSceneResumeReconnectFailureUsesLocalizedMessageNotRawNIOSSHText()
        async throws
    {
        let fixture = try Phase3HerdrFixtures.single()
        let client = Phase2SSHClient(
            presentedFingerprint: "SHA256:phase4-test-key",
            outcomes: [false, true]
        )
        let application = makePhase4NavigationApplication(
            fixture: fixture,
            client: client
        )
        let host = phase4Host()
        try await application.save(host)

        application.model.connect(to: host)
        try await waitUntil { application.model.activeConnection != nil }
        application.model.selectOrdinaryTerminalFromPicker()
        try await waitUntil { application.model.herdrState == .ordinaryTerminal }
        let oldSession = try XCTUnwrap(
            application.model.activeConnection?.session
        )

        application.model.sceneWillResignActive()
        await application.model.sceneDidEnterBackground()
        await application.transport.simulateBaseSessionDeath()
        await application.model.handleTerminalSessionClosed(
            for: ObjectIdentifier(oldSession)
        )
        await application.model.sceneDidBecomeActive()

        XCTAssertNil(application.model.activeConnection)
        XCTAssertEqual(
            application.model.errorMessage,
            RootViewModel.transparentReconnectFailureMessage
        )
        XCTAssertFalse(
            application.model.errorMessage?
                .localizedCaseInsensitiveContains("NIOSSH") ?? true
        )
        XCTAssertFalse(
            application.model.errorMessage?
                .localizedCaseInsensitiveContains("connectTimeout") ?? true
        )
    }

    // MARK: Error presentation

    func testTimeoutUnreachableAndRefusedErrorsHaveDistinctLocalizedStrings() async {
        let failures: [Phase9RawNetworkFailure] = [
            .timedOut,
            .unreachable,
            .refused,
        ]
        var messages: [String] = []

        for failure in failures {
            let application = makePhase9NetworkApplication(
                client: Phase9FailingSSHClient(failure: failure)
            )
            do {
                _ = try await application.connect(
                    to: phase9Host(preferredTransport: .ssh),
                    credentials: phase2Credentials(),
                    hostKeyDecision: { _ in .accept }
                )
                XCTFail("The configured network failure must be thrown")
            } catch let error as ConnectionError {
                messages.append(error.localizedDescription)
                XCTAssertFalse(
                    error.localizedDescription.contains("NIOSSH"),
                    "Low-level NIOSSH text must not reach the UI"
                )
            } catch {
                XCTFail("Expected a presentable ConnectionError, got: \(error)")
            }
        }

        XCTAssertEqual(
            messages,
            [
                "The SSH connection timed out.",
                "The SSH host is unreachable.",
                "The SSH host refused the connection.",
            ]
        )
        XCTAssertEqual(Set(messages).count, 3)
        XCTAssertTrue(messages.allSatisfy { !$0.isEmpty })
    }

    private func assertStaggeredStart(
        first: ContinuousClock.Instant,
        second: ContinuousClock.Instant,
        stagger: Duration
    ) {
        let delay = first.duration(to: second)
        XCTAssertGreaterThanOrEqual(
            delay,
            stagger - .milliseconds(50),
            "The alternate family must wait for the documented stagger, not start at t=0"
        )
        XCTAssertLessThan(
            delay,
            .milliseconds(800),
            "The stagger must not wait for the dead family's connect timeout"
        )
    }

    private func waitForAttemptStart(
        _ address: Phase9ResolvedAddress,
        connector: Phase9BlockingAddressConnector,
        timeoutMilliseconds: Int = 600
    ) async -> Bool {
        let pollMilliseconds = 10
        for _ in 0..<(timeoutMilliseconds / pollMilliseconds) {
            if await connector.hasStarted(address) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(pollMilliseconds))
        }
        return await connector.hasStarted(address)
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        timeoutSeconds: Double = 2
    ) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        struct ConditionTimeout: Error {}
        throw ConditionTimeout()
    }
}
