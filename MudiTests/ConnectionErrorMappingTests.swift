import HerdrKit
@preconcurrency import NIOCore
import XCTest
@testable import Mudi

/// A TestFlight user with a mistyped SSH username saw "Unable to connect to
/// the SSH host": authentication failures must stay distinguishable from
/// network failures at the coordinator boundary.
final class ConnectionErrorMappingTests: XCTestCase {
    private func makeCoordinator() -> ApplicationCoordinator {
        ApplicationCoordinator()
    }

    func testShellAuthenticationFailureMapsToAuthenticationFailed() async {
        let mapped = await makeCoordinator().mapConnectionError(
            SSHShellError.authenticationFailed
        )
        XCTAssertEqual(mapped, .authenticationFailed)
    }

    func testSSHClientAuthenticationFailureMapsToAuthenticationFailed() async {
        let mapped = await makeCoordinator().mapConnectionError(
            SSHClientError.authenticationFailed
        )
        XCTAssertEqual(mapped, .authenticationFailed)
    }

    func testAuthenticationFailedHasActionableDescription() {
        let description = ConnectionError.authenticationFailed.errorDescription
        XCTAssertNotNil(description)
        XCTAssertTrue(
            description?.localizedCaseInsensitiveContains("authentication") == true,
            "description should name authentication: \(description ?? "nil")"
        )
    }

    func testShellConnectionFailureStillMapsToConnectionFailed() async {
        let mapped = await makeCoordinator().mapConnectionError(
            SSHShellError.connectionFailed
        )
        XCTAssertEqual(mapped, .connectionFailed)
    }

    func testNetworkErrorsKeepTheirClassification() async {
        let coordinator = makeCoordinator()
        let timeout = await coordinator.mapConnectionError(
            ChannelError.connectTimeout(.seconds(1))
        )
        XCTAssertEqual(timeout, .connectionTimedOut)
        let refused = await coordinator.mapConnectionError(
            IOError(errnoCode: ECONNREFUSED, reason: "refused")
        )
        XCTAssertEqual(refused, .connectionRefused)
    }
}
