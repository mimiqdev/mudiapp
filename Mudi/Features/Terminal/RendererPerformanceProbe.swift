import Foundation
import QuartzCore

/// Disabled by default; benchmark observers must opt in per view. CPU timers
/// describe their named stage, never GPU execution or presentation latency.
@MainActor
final class RendererPerformanceProbe {
    private(set) var milliseconds: [String: [Double]] = [:]
    func record(_ stage: String, since start: CFTimeInterval) {
        milliseconds[stage, default: []].append((CACurrentMediaTime() - start) * 1_000)
    }
    func reset() { milliseconds.removeAll(keepingCapacity: true) }
}
