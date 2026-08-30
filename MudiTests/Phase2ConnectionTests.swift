import Foundation
import HerdrKit
import XCTest
@testable import Mudi

final class Phase2ConnectionTests: XCTestCase {
    func testHostKeyDecisionHandshakeAllowsTimeForUserResponse() {
        let timeout = NIOSSHConnection.hostKeyDecisionTimeout.nanoseconds
        XCTAssertGreaterThan(timeout, Int64(10_000_000_000))
    }

    func testUnknownHostKeyAcceptanceRemembersFingerprintAndContinuesSameConnection() async throws {
        let host = phase2Host()
        let credentials = phase2Credentials()
        let fingerprint = "SHA256:first-seen-key"
        let knownHostKeys = Phase2KnownHostKeys()
        let client = Phase2SSHClient(presentedFingerprint: fingerprint)
        let application = makeMissingPhase2Application(
            knownHostKeys: knownHostKeys,
            client: client
        )
        let prompt = Phase2HostKeyPrompt(decision: .accept)

        let state = try await application.connect(
            to: host,
            credentials: credentials,
            hostKeyDecision: { presentedFingerprint in
                await prompt.decide(for: presentedFingerprint)
            }
        )

        let promptedFingerprints = await prompt.fingerprints()
        XCTAssertEqual(promptedFingerprints, [fingerprint])
        let rememberedFingerprint = await knownHostKeys.fingerprint(for: host)
        XCTAssertEqual(rememberedFingerprint, fingerprint)
        let attempts = await client.connectionAttempts()
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(state, .connected)
    }

    func testUnknownHostKeyRejectionDoesNotEstablishSession() async throws {
        let host = phase2Host()
        let client = Phase2SSHClient(presentedFingerprint: "SHA256:rejected-key")
        let knownHostKeys = Phase2KnownHostKeys()
        let application = makeMissingPhase2Application(
            knownHostKeys: knownHostKeys,
            client: client
        )
        let prompt = Phase2HostKeyPrompt(decision: .reject)

        do {
            _ = try await application.connect(
                to: host,
                credentials: phase2Credentials(),
                hostKeyDecision: { presentedFingerprint in
                    await prompt.decide(for: presentedFingerprint)
                }
            )
            XCTFail("Expected rejecting an unknown host key to abort the connection")
        } catch let error as Phase2ConnectionError {
            XCTAssertEqual(error, .hostKeyRejected)
        } catch {
            XCTFail("Expected a host-key rejection error, got: \(error)")
        }

        let attempts = await client.connectionAttempts()
        XCTAssertEqual(attempts, 1)
        let connectionState = await application.connectionState()
        XCTAssertNotEqual(connectionState, .connected)
        let rememberedFingerprint = await knownHostKeys.fingerprint(for: host)
        XCTAssertNil(rememberedFingerprint)
    }

    func testChangedHostKeyFailsWithPresentableError() async throws {
        let host = phase2Host()
        let knownHostKeys = Phase2KnownHostKeys()
        let rememberedFingerprint = "SHA256:original-key"
        let changedFingerprint = "SHA256:changed-key"
        await knownHostKeys.remember(rememberedFingerprint, for: host)
        let client = Phase2SSHClient(presentedFingerprint: changedFingerprint)
        let application = makeMissingPhase2Application(
            knownHostKeys: knownHostKeys,
            client: client
        )

        do {
            _ = try await application.connect(
                to: host,
                credentials: phase2Credentials(),
                hostKeyDecision: { _ in .accept }
            )
            XCTFail("Expected a changed host key to abort the connection")
        } catch let error as Phase2ConnectionError {
            XCTAssertEqual(
                error,
                .hostKeyMismatch(
                    expected: rememberedFingerprint,
                    actual: changedFingerprint
                )
            )
            XCTAssertFalse(error.localizedDescription.isEmpty)
        } catch {
            XCTFail("Expected a presentable host-key mismatch error, got: \(error)")
        }

        let attempts = await client.connectionAttempts()
        XCTAssertEqual(attempts, 1)
    }

    func testSessionEntersConnectingThenConnected() async throws {
        let client = Phase2SSHClient(presentedFingerprint: "SHA256:known-key")
        let application = makeMissingPhase2Application(client: client)

        let stateStream = await application.connectionStateStream()
        let observedStatesTask = Task {
            await firstPhase2States(from: stateStream, count: 2)
        }
        let state = try await application.connect(
            to: phase2Host(),
            credentials: phase2Credentials(),
            hostKeyDecision: { _ in .accept }
        )

        let observedStates = await observedStatesTask.value
        XCTAssertEqual(state, .connected)
        XCTAssertEqual(observedStates, [.connecting, .connected])
        let currentState = await application.connectionState()
        XCTAssertEqual(currentState, .connected)
    }

    func testFailedConnectionIsVisibleAsFailedState() async throws {
        let client = Phase2SSHClient(
            presentedFingerprint: "SHA256:known-key",
            outcomes: [true]
        )
        let application = makeMissingPhase2Application(client: client)

        do {
            _ = try await application.connect(
                to: phase2Host(),
                credentials: phase2Credentials(),
                hostKeyDecision: { _ in .accept }
            )
            XCTFail("Expected the configured SSH connection to fail")
        } catch let error as Phase2ConnectionError {
            XCTAssertEqual(error, .connectionFailed)
        } catch {
            XCTFail("Expected a connection failure, got: \(error)")
        }

        let currentState = await application.connectionState()
        XCTAssertEqual(currentState, .failed)
    }

    func testDisconnectIsVisibleAsDisconnectedState() async throws {
        let client = Phase2SSHClient(presentedFingerprint: "SHA256:known-key")
        let application = makeMissingPhase2Application(client: client)

        let connectedState = try await application.connect(
            to: phase2Host(),
            credentials: phase2Credentials(),
            hostKeyDecision: { _ in .accept }
        )
        XCTAssertEqual(connectedState, .connected)
        await application.disconnect()

        let currentState = await application.connectionState()
        XCTAssertEqual(currentState, .disconnected)
    }

    func testManualReconnectAfterDisconnectCallsConnectAgain() async throws {
        let client = Phase2SSHClient(
            presentedFingerprint: "SHA256:known-key",
            outcomes: [false, false]
        )
        let application = makeMissingPhase2Application(client: client)
        let host = phase2Host()
        let credentials = phase2Credentials()
        try await application.save(host)
        try await application.save(credentials, for: host)

        let connectedState = try await application.connect(
            to: host,
            credentials: credentials,
            hostKeyDecision: { _ in .accept }
        )
        XCTAssertEqual(connectedState, .connected)
        await application.disconnect()
        let reconnectedState = try await application.reconnect()

        XCTAssertEqual(reconnectedState, .connected)
        let attempts = await client.connectionAttempts()
        XCTAssertEqual(attempts, 2)
    }

    func testManualReconnectAfterFailureCallsConnectAgain() async throws {
        let client = Phase2SSHClient(
            presentedFingerprint: "SHA256:known-key",
            outcomes: [true, false]
        )
        let application = makeMissingPhase2Application(client: client)
        let host = phase2Host()
        let credentials = phase2Credentials()
        try await application.save(host)
        try await application.save(credentials, for: host)

        do {
            _ = try await application.connect(
                to: host,
                credentials: credentials,
                hostKeyDecision: { _ in .accept }
            )
            XCTFail("Expected the first SSH connection to fail")
        } catch let error as Phase2ConnectionError {
            XCTAssertEqual(error, .connectionFailed)
        } catch {
            XCTFail("Expected a connection failure, got: \(error)")
        }
        let reconnectedState = try await application.reconnect()

        XCTAssertEqual(reconnectedState, .connected)
        let attempts = await client.connectionAttempts()
        XCTAssertEqual(attempts, 2)
    }

    func testReconnectReloadsLatestHostAndCredentials() async throws {
        let host = phase2Host()
        let updatedHost = Host(
            id: host.id,
            displayName: host.displayName,
            hostname: "new.example.test",
            port: 2200,
            username: "new-user",
            preferredTransport: .ssh
        )
        let credentials = phase2Credentials()
        let updatedCredentials = SSHCredentials(password: "updated-password")
        let client = Phase2SSHClient(presentedFingerprint: "SHA256:known-key")
        let application = makeMissingPhase2Application(client: client)

        try await application.save(host)
        try await application.save(credentials, for: host)
        _ = try await application.connect(
            to: host,
            credentials: credentials,
            hostKeyDecision: { _ in .accept }
        )
        await application.disconnect()

        try await application.save(updatedHost)
        try await application.save(updatedCredentials, for: updatedHost)
        _ = try await application.reconnect()

        let records = await client.connectionRecords()
        XCTAssertEqual(records.map(\.host), [host, updatedHost])
        XCTAssertEqual(records.map(\.credentials), [credentials, updatedCredentials])
    }

    func testDisconnectRejectsReconnectWhileHandshakeIsInFlight() async throws {
        let gate = Phase2ConnectionGate()
        let client = Phase2SSHClient(
            presentedFingerprint: "SHA256:known-key",
            firstConnectionGate: gate
        )
        let application = makeMissingPhase2Application(client: client)
        let firstConnect = Task {
            try? await application.connect(
                to: phase2Host(),
                credentials: phase2Credentials(),
                hostKeyDecision: { _ in .accept }
            )
        }

        await gate.waitUntilStarted()
        await application.disconnect()

        do {
            _ = try await application.reconnect()
            XCTFail("Expected reconnect to be rejected while the first handshake is active")
        } catch let error as Phase2ConnectionError {
            XCTAssertEqual(error, .connectionFailed)
        } catch {
            XCTFail("Expected reconnect rejection, got: \(error)")
        }
        let attempts = await client.connectionAttempts()
        XCTAssertEqual(attempts, 1)

        await gate.release()
        let firstResult = await firstConnect.value
        XCTAssertNil(firstResult)
        let state = await application.connectionState()
        XCTAssertEqual(state, .disconnected)
        let session = await application.activeShellSession()
        XCTAssertNil(session)
    }
}
