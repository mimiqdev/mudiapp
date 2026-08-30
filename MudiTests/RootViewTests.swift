import XCTest
@testable import Mudi

@MainActor
final class RootViewTests: XCTestCase {
    func testApplicationSkeletonLoads() {
        _ = RootView()
    }

    func testFailedConnectionDismissesHostKeyPromptAndRejectsLateAccept() async throws {
        let host = phase2Host()
        let knownHostKeys = Phase2KnownHostKeys()
        let callbackStarted = Phase2ConnectionGate()
        let failureGate = Phase2ConnectionGate()
        let client = Phase2SSHClient(
            presentedFingerprint: "SHA256:late-key",
            callbackStartedGate: callbackStarted,
            failureGate: failureGate,
            failAfterStartingHostKeyDecision: true
        )
        let application = makeMissingPhase2Application(
            knownHostKeys: knownHostKeys,
            client: client
        )
        let credentials = phase2Credentials()
        try await application.save(host)
        try await application.save(credentials, for: host)
        let model = RootViewModel(coordinator: application)

        model.connect(to: host)
        await callbackStarted.waitUntilStarted()
        let promptShown = await waitForRootViewCondition { model.hostKeyPrompt != nil }
        XCTAssertTrue(promptShown)
        await failureGate.release()
        let connectionFailed = await waitForRootViewCondition { model.connectionState == .failed }
        XCTAssertTrue(connectionFailed)
        XCTAssertNil(model.hostKeyPrompt)

        model.answerHostKeyPrompt(.accept)
        try await Task.sleep(nanoseconds: 10_000_000)

        let rememberedFingerprint = await knownHostKeys.fingerprint(for: host)
        XCTAssertNil(rememberedFingerprint)
    }

    func testReconnectUsesFreshHostKeyPromptAfterFirstAttemptFailed() async throws {
        let host = phase2Host()
        let knownHostKeys = Phase2KnownHostKeys()
        let callbackStarted = Phase2ConnectionGate()
        let failureGate = Phase2ConnectionGate()
        let client = Phase2SSHClient(
            presentedFingerprint: "SHA256:reconnect-key",
            callbackStartedGate: callbackStarted,
            failureGate: failureGate,
            failAfterStartingHostKeyDecision: true
        )
        let application = makeMissingPhase2Application(
            knownHostKeys: knownHostKeys,
            client: client
        )
        try await application.save(host)
        try await application.save(phase2Credentials(), for: host)
        let model = RootViewModel(coordinator: application)

        model.connect(to: host)
        await callbackStarted.waitUntilStarted()
        let firstPromptShown = await waitForRootViewCondition { model.hostKeyPrompt != nil }
        XCTAssertTrue(firstPromptShown)
        model.answerHostKeyPrompt(.reject)
        await failureGate.release()
        let firstConnectionFailed = await waitForRootViewCondition { model.connectionState == .failed }
        XCTAssertTrue(firstConnectionFailed)
        let rememberedAfterRejection = await knownHostKeys.fingerprint(for: host)
        XCTAssertNil(rememberedAfterRejection)

        model.reconnect()
        let reconnectPromptShown = await waitForRootViewCondition { model.hostKeyPrompt != nil }
        XCTAssertTrue(reconnectPromptShown)
        model.answerHostKeyPrompt(.accept)

        let reconnected = await waitForRootViewCondition { model.connectionState == .connected }
        XCTAssertTrue(reconnected)
        let rememberedAfterReconnect = await knownHostKeys.fingerprint(for: host)
        XCTAssertEqual(rememberedAfterReconnect, "SHA256:reconnect-key")
    }

    func testDeletingActiveHostDismissesHostKeyPrompt() async throws {
        let host = phase2Host()
        let client = Phase2SSHClient(presentedFingerprint: "SHA256:pending-key")
        let application = makeMissingPhase2Application(client: client)
        try await application.save(host)
        try await application.save(phase2Credentials(), for: host)
        let model = RootViewModel(coordinator: application)

        model.connect(to: host)
        let promptShown = await waitForRootViewCondition { model.hostKeyPrompt != nil }
        XCTAssertTrue(promptShown)

        model.delete(host)
        let hostsDeleted = await waitForRootViewCondition { model.hosts.isEmpty }
        XCTAssertTrue(hostsDeleted)
        XCTAssertNil(model.hostKeyPrompt)

        model.answerHostKeyPrompt(.reject)
    }

    private func waitForRootViewCondition(
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<200 {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }
}
