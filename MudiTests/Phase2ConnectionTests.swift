import Foundation
import HerdrKit
import XCTest
@testable import Mudi

final class Phase2ConnectionTests: XCTestCase {
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

        let state = try? await application.connect(
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
        XCTAssertEqual(attempts, 0)
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
        XCTAssertEqual(attempts, 0)
    }

    func testSessionEntersConnectingThenConnected() async throws {
        let client = Phase2SSHClient(presentedFingerprint: "SHA256:known-key")
        let application = makeMissingPhase2Application(client: client)

        let state = try? await application.connect(
            to: phase2Host(),
            credentials: phase2Credentials(),
            hostKeyDecision: { _ in .accept }
        )

        XCTAssertEqual(state, .connected)
        let stateHistory = await application.stateHistory()
        XCTAssertEqual(stateHistory, [.connecting, .connected])
        let currentState = await application.connectionState()
        XCTAssertEqual(currentState, .connected)
    }

    func testFailedConnectionIsVisibleAsFailedState() async throws {
        let client = Phase2SSHClient(
            presentedFingerprint: "SHA256:known-key",
            outcomes: [true]
        )
        let application = makeMissingPhase2Application(client: client)

        _ = try? await application.connect(
            to: phase2Host(),
            credentials: phase2Credentials(),
            hostKeyDecision: { _ in .accept }
        )

        let currentState = await application.connectionState()
        XCTAssertEqual(currentState, .failed)
        let stateHistory = await application.stateHistory()
        XCTAssertEqual(stateHistory, [.connecting, .failed])
    }

    func testDisconnectIsVisibleAsDisconnectedState() async throws {
        let client = Phase2SSHClient(presentedFingerprint: "SHA256:known-key")
        let application = makeMissingPhase2Application(client: client)

        _ = try? await application.connect(
            to: phase2Host(),
            credentials: phase2Credentials(),
            hostKeyDecision: { _ in .accept }
        )
        await application.disconnect()

        let currentState = await application.connectionState()
        XCTAssertEqual(currentState, .disconnected)
        let stateHistory = await application.stateHistory()
        XCTAssertEqual(stateHistory, [.connecting, .connected, .disconnected])
    }

    func testManualReconnectAfterDisconnectCallsConnectAgain() async throws {
        let client = Phase2SSHClient(
            presentedFingerprint: "SHA256:known-key",
            outcomes: [false, false]
        )
        let application = makeMissingPhase2Application(client: client)

        _ = try? await application.connect(
            to: phase2Host(),
            credentials: phase2Credentials(),
            hostKeyDecision: { _ in .accept }
        )
        await application.disconnect()
        let reconnectedState = try? await application.reconnect()

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

        _ = try? await application.connect(
            to: phase2Host(),
            credentials: phase2Credentials(),
            hostKeyDecision: { _ in .accept }
        )
        let reconnectedState = try? await application.reconnect()

        XCTAssertEqual(reconnectedState, .connected)
        let attempts = await client.connectionAttempts()
        XCTAssertEqual(attempts, 2)
    }
}
