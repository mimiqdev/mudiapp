import CoreGraphics
import Foundation

/// Figma's 120° arc, rotated into available space when invoked near an edge.
struct ThumbArcLayout {
    let origin: CGPoint
    let centers: [CGPoint]
    init(origin: CGPoint, bounds: CGRect, count: Int, isLeftHanded: Bool) {
        self.origin = origin
        let count = min(max(count, 0), 6)
        guard count > 0, bounds.width >= 90, bounds.height >= 90 else { centers = []; return }
        let safe = bounds.insetBy(dx: 23, dy: 23)
        let anchor = CGPoint(x: min(max(origin.x, safe.minX), safe.maxX), y: min(max(origin.y, safe.minY), safe.maxY))
        func points(start: Double, radius: CGFloat) -> [CGPoint] {
            (0..<count).map { index in
                let angle = (start + (count == 1 ? 60 : Double(index) * 120 / Double(count - 1))) * .pi / 180
                let x = cos(angle) * radius * (isLeftHanded ? -1 : 1)
                return CGPoint(x: anchor.x + x, y: anchor.y + sin(angle) * radius)
            }
        }
        var result: [CGPoint]?
        for radius: CGFloat in [122, 112, 102, 92, 82, 72] {
            for start: Double in [165, 75, 255, -15, 135, 105, 225, 285, 45, 15, 195, -45] {
                let candidate = points(start: start, radius: radius)
                if candidate.allSatisfy({ safe.contains($0) }) { result = candidate; break }
            }
            if result != nil { break }
        }
        if let result { centers = result }
        else {
            // Very narrow or short layouts still keep every target on screen.
            let candidate = points(start: 165, radius: 92)
            let minX = candidate.map(\.x).min() ?? 0, maxX = candidate.map(\.x).max() ?? 0
            let minY = candidate.map(\.y).min() ?? 0, maxY = candidate.map(\.y).max() ?? 0
            let dx = minX < safe.minX ? safe.minX - minX : maxX > safe.maxX ? safe.maxX - maxX : 0
            let dy = minY < safe.minY ? safe.minY - minY : maxY > safe.maxY ? safe.maxY - maxY : 0
            centers = candidate.map { CGPoint(x: min(max($0.x + dx, safe.minX), safe.maxX), y: min(max($0.y + dy, safe.minY), safe.maxY)) }
        }
    }
    func selectedIndex(at point: CGPoint) -> Int? {
        guard hypot(point.x - origin.x, point.y - origin.y) > 30 else { return nil }
        let nearest = centers.enumerated().min {
            hypot($0.element.x - point.x, $0.element.y - point.y) < hypot($1.element.x - point.x, $1.element.y - point.y)
        }
        guard let nearest, hypot(nearest.element.x - point.x, nearest.element.y - point.y) <= 27 else { return nil }
        return nearest.offset
    }
}
