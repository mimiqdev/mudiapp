import HerdrKit
import UIKit

/// Session output consumption for ShellTerminalView: pumps bytes from the
/// SSH stream into the terminal grid and reports normal/error closure.
@MainActor
extension ShellTerminalView {
    func consumeOutput(
        of session: SSHShellSession,
        identity: ObjectIdentifier
    ) async {
        let output = await session.outputStream()
        do {
            for try await bytes in output {
                guard isActive(identity) else { return }
                guard !bytes.isEmpty else { continue }
                feed(byteArray: bytes[...])
            }
            await finishNormally(session, identity: identity)
        } catch {
            guard isActive(identity) else { return }
            await session.disconnect()
            guard isActive(identity) else { return }
            report(error)
        }
    }

    private func finishNormally(
        _ session: SSHShellSession,
        identity: ObjectIdentifier
    ) async {
        guard isActive(identity) else { return }
        didCloseNormally = true
        await session.disconnect()
        guard isActive(identity) else { return }
        onClosed?()
    }

    private func isActive(_ identity: ObjectIdentifier) -> Bool {
        !Task.isCancelled && sessionIdentity == identity
    }
}
