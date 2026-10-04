import CoreGraphics
import Foundation

/// The visible buttons label a directional marking menu; they are not hit targets.
struct ThumbArcLayout {
    static let cancelRadius: CGFloat = 18
    let origin: CGPoint
    let centers: [CGPoint]
    private let startAngle: Double
    private let direction: Double
    private let span = 120.0

    init(origin: CGPoint, bounds: CGRect, count: Int, isLeftHanded: Bool) {
        self.origin = origin
        let sweep = isLeftHanded ? -1.0 : 1.0
        direction = sweep
        let count = min(max(count, 0), 6)
        guard count > 0, bounds.width >= 90, bounds.height >= 90 else {
            centers = []; startAngle = 0; return
        }
        let safe = bounds.insetBy(dx: 23, dy: 23)
        let radius = min(110, min(safe.width, safe.height) / 1.6)
        func points(start: Double) -> [CGPoint] {
            (0..<count).map { index in
                let angle = (start + sweep * (Double(index) + 0.5) * 120 / Double(count)) * .pi / 180
                return CGPoint(x: origin.x + cos(angle) * radius, y: origin.y + sin(angle) * radius)
            }
        }
        // Prefer the designed up-left arc, then rotate the entire arc and its sectors.
        let additional: [Double] = (1...11).flatMap { index -> [Double] in
            let offset = Double(index) * 15
            return [offset, -offset]
        }
        let rotations: [Double] = [0, 90, -90, 180] + additional
        var bestStart = isLeftHanded ? 15.0 : 165.0
        var bestPoints = points(start: bestStart)
        var bestOverflow = CGFloat.greatestFiniteMagnitude
        for rotation in rotations {
            let start = isLeftHanded ? 15 - rotation : 165 + rotation
            let candidate = points(start: start)
            let overflow = candidate.reduce(CGFloat.zero) { total, point in
                let horizontal = max(safe.minX - point.x, 0) + max(point.x - safe.maxX, 0)
                let vertical = max(safe.minY - point.y, 0) + max(point.y - safe.maxY, 0)
                return total + horizontal + vertical
            }
            if overflow < bestOverflow {
                bestStart = start; bestPoints = candidate; bestOverflow = overflow
            }
            if overflow == 0 { break }
        }
        startAngle = bestStart
        // At an extreme corner, shift only the labels into view. The touch point and
        // directional sectors stay anchored to the finger, so travel is still short.
        let minX = bestPoints.map(\.x).min()!, maxX = bestPoints.map(\.x).max()!
        let minY = bestPoints.map(\.y).min()!, maxY = bestPoints.map(\.y).max()!
        let dx = minX < safe.minX ? safe.minX - minX : maxX > safe.maxX ? safe.maxX - maxX : 0
        let dy = minY < safe.minY ? safe.minY - minY : maxY > safe.maxY ? safe.maxY - maxY : 0
        centers = bestPoints.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
    }

    func selectedIndex(at point: CGPoint, previous: Int? = nil,
                       activationDistance: CGFloat = 28, isActivated: Bool = false) -> Int? {
        guard !centers.isEmpty else { return nil }
        let dx = point.x - origin.x, dy = point.y - origin.y
        let distance = hypot(dx, dy)
        guard distance >= Self.cancelRadius,
              isActivated || previous != nil || distance >= activationDistance else { return nil }
        var angle = (atan2(dy, dx) * 180 / .pi - startAngle) * direction
        angle = (angle + 180).truncatingRemainder(dividingBy: 360)
        if angle < 0 { angle += 360 }
        angle -= 180
        guard angle >= -15, angle <= span + 15 else { return nil }
        let step = span / Double(centers.count)
        let candidate = min(max(Int(floor(angle / step)), 0), centers.count - 1)
        if let previous, centers.indices.contains(previous), candidate != previous,
           angle >= Double(previous) * step - 2, angle <= Double(previous + 1) * step + 2 {
            return previous
        }
        return candidate
    }
}
