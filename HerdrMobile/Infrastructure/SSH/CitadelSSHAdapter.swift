import Citadel
import HerdrKit

/// Citadel-backed implementation will be introduced by the SSH vertical slice.
/// Keeping the dependency behind this boundary prevents it from leaking into features.
enum CitadelSSHAdapter {
    static let transportKind = ActiveTransport.ssh
}
