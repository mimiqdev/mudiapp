@preconcurrency import Citadel
import Crypto
import Foundation
import HerdrKit
@preconcurrency import NIO
@preconcurrency import NIOCore
@preconcurrency import NIOSSH

/// A Citadel-backed implementation of the HerdrKit SSH shell boundary.
///
/// The Citadel client and its authentication method are retained only by the
/// active PTY channel. Closing that channel closes the SSH client as well.
struct CitadelSSHAdapter: HerdrKit.SSHClient, HerdrKit.HostKeyAwareSSHClient {
    static let transportKind = ActiveTransport.ssh

    /// The legacy shell boundary has no way to ask a caller about an unknown
    /// key, so it fails closed. The application uses the host-key-aware
    /// overload below for all user connections.
    func connect(
        to host: HerdrKit.Host,
        credentials: HerdrKit.SSHCredentials
    ) async throws -> any PTYChannel {
        try await connect(
            to: host,
            credentials: credentials,
            hostKeyDecision: { _ in .reject }
        )
    }

    func connect(
        to host: HerdrKit.Host,
        credentials: HerdrKit.SSHCredentials,
        hostKeyDecision: @escaping @Sendable (String) async -> HerdrKit.HostKeyDecision
    ) async throws -> any PTYChannel {
        let authenticationMethod = try makeAuthenticationMethod(
            for: host,
            credentials: credentials
        )
        let hostKeyValidator = Citadel.SSHHostKeyValidator.custom(
            CitadelHostKeyValidator(decision: hostKeyDecision)
        )

        let connection: NIOSSHConnection
        do {
            connection = try await NIOSSHConnection.connect(
                host: host,
                authenticationMethod: authenticationMethod,
                hostKeyValidator: hostKeyValidator
            )
        } catch is CitadelHostKeyRejected {
            throw HerdrKit.ConnectionError.hostKeyRejected
        } catch let error as Citadel.SSHClientError {
            switch error {
            case .allAuthenticationOptionsFailed,
                 .unsupportedPasswordAuthentication,
                 .unsupportedPrivateKeyAuthentication,
                 .unsupportedHostBasedAuthentication:
                throw HerdrKit.SSHClientError.authenticationFailed
            case .channelCreationFailed:
                throw error
            }
        } catch is Citadel.AuthenticationFailed {
            throw HerdrKit.SSHClientError.authenticationFailed
        }

        let channel = CitadelPTYChannel(connection: connection)
        do {
            try await channel.start()
            return channel
        } catch {
            await channel.close()
            throw error
        }
    }

    private func makeAuthenticationMethod(
        for host: HerdrKit.Host,
        credentials: HerdrKit.SSHCredentials
    ) throws -> Citadel.SSHAuthenticationMethod {
        if let password = credentials.password, !password.isEmpty {
            return .passwordBased(username: host.username, password: password)
        }

        guard let pemPrivateKey = credentials.pemPrivateKey,
              !pemPrivateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw HerdrKit.SSHClientError.authenticationFailed
        }

        do {
            switch try Citadel.SSHKeyDetection.detectPrivateKeyType(from: pemPrivateKey) {
            case .ed25519:
                let key = try Curve25519.Signing.PrivateKey(sshEd25519: pemPrivateKey)
                return .ed25519(username: host.username, privateKey: key)
            case .rsa:
                let key = try Insecure.RSA.PrivateKey(sshRsa: pemPrivateKey)
                return .rsa(username: host.username, privateKey: key)
            default:
                throw HerdrKit.SSHClientError.authenticationFailed
            }
        } catch let error as HerdrKit.SSHClientError {
            throw error
        } catch {
            throw HerdrKit.SSHClientError.authenticationFailed
        }
    }
}

private enum CitadelHostKeyRejected: Error {
    case rejected
}

private final class CitadelHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let decision: @Sendable (String) async -> HerdrKit.HostKeyDecision

    init(decision: @escaping @Sendable (String) async -> HerdrKit.HostKeyDecision) {
        self.decision = decision
    }

    func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        let fingerprint = Self.fingerprint(for: hostKey)
        Task {
            let decision = await decision(fingerprint)
            switch decision {
            case .accept:
                validationCompletePromise.succeed(())
            case .reject:
                validationCompletePromise.fail(CitadelHostKeyRejected.rejected)
            }
        }
    }

    private static func fingerprint(for hostKey: NIOSSHPublicKey) -> String {
        var buffer = ByteBuffer()
        hostKey.write(to: &buffer)
        let digest = SHA256.hash(data: Data(buffer.readableBytesView))
        let encodedDigest = Data(digest).base64EncodedString()
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "SHA256:\(encodedDigest)"
    }
}
