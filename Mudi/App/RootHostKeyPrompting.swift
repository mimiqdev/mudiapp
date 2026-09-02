import Foundation
import HerdrKit

/// Host-key prompting for RootViewModel: the pending decision continuation
/// bridging the coordinator's asynchronous host-key callback to the
/// RootView alert.
@MainActor
extension RootViewModel {
    func requestHostKeyDecision(
        for fingerprint: String,
        generation: UUID
    ) async -> HostKeyDecision {
        guard connectionGeneration == generation,
              connectionState == .connecting
        else {
            return .reject
        }

        return await withCheckedContinuation { continuation in
            guard connectionGeneration == generation,
                  connectionState == .connecting
            else {
                continuation.resume(returning: .reject)
                return
            }
            pendingHostKeyDecision?.resume(returning: .reject)
            pendingHostKeyDecision = continuation
            let prompt = HostKeyPrompt(fingerprint: fingerprint)
            pendingHostKeyPromptID = prompt.id
            hostKeyPrompt = prompt
        }
    }

    func answerHostKeyPrompt(_ decision: HostKeyDecision, for promptID: UUID? = nil) {
        guard promptID == nil || promptID == pendingHostKeyPromptID else { return }
        guard let pendingHostKeyDecision else {
            hostKeyPrompt = nil
            pendingHostKeyPromptID = nil
            return
        }
        self.pendingHostKeyDecision = nil
        pendingHostKeyPromptID = nil
        hostKeyPrompt = nil
        pendingHostKeyDecision.resume(returning: decision)
    }

}
