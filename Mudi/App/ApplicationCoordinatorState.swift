import Foundation
import HerdrKit

extension ApplicationCoordinator {
    func connectionState() -> ConnectionState {
        state
    }

    /// Returns lifecycle events after subscription. The stream intentionally
    /// does not replay the initial idle state, so a connection reports the
    /// meaningful `connecting` → `connected` transition to new observers.
    func connectionStateStream() -> AsyncStream<ConnectionState> {
        let id = UUID()
        return AsyncStream { continuation in
            stateContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task {
                    await self?.removeStateContinuation(id)
                }
            }
        }
    }

    /// The authenticated SSH bootstrap session used by Herdr discovery.
    func activeShellSession() -> SSHShellSession? {
        session
    }

    /// The session carrying the interactive terminal. It is the SSH bootstrap
    /// session when Mosh was unavailable and a Mosh-backed session otherwise.
    func activeTerminalSession() -> SSHShellSession? {
        terminalSession ?? session
    }

    func activeTransport() -> ActiveTransport? {
        activeTransportValue
    }

    /// The transient Host value carrying the actual selected address. The
    /// stable ID and saved endpoint list remain unchanged.
    func activeHost() -> Host? {
        activeHostValue
    }

    func lastAutomaticMoshFailureClass() -> MoshFailureClass? {
        lastAutomaticMoshFailure
    }
}
