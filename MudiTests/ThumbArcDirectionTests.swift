import UIKit
import XCTest
@testable import Mudi

@MainActor
final class ThumbArcDirectionTests: XCTestCase {
    private let origin = CGPoint(x: 300, y: 300)
    private func point(_ degrees: Double, distance: CGFloat) -> CGPoint {
        let angle = degrees * .pi / 180
        return CGPoint(x: origin.x + cos(angle) * distance, y: origin.y + sin(angle) * distance)
    }
    private func overlay(_ preferences: ThumbArcPreferences = ThumbArcPreferences()) -> MudiThumbArcOverlay {
        let view = MudiThumbArcOverlay()
        view.frame = CGRect(x: 0, y: 0, width: 600, height: 600)
        view.begin(origin: origin, preferences: preferences)
        return view
    }
    func testDirectionSelectsAtShortAndLongTravelWithoutReachingLabels() {
        let layout = ThumbArcLayout(origin: origin, bounds: CGRect(x: 0, y: 0, width: 600, height: 600),
                                    count: 6, isLeftHanded: false)
        for index in 0..<6 {
            let direction = 175 + Double(index) * 20
            for distance: CGFloat in [35, 70, 240] {
                XCTAssertEqual(layout.selectedIndex(at: point(direction, distance: distance)), index)
            }
        }
        XCTAssertEqual(layout.selectedIndex(at: point(151, distance: 35)), 0)
        XCTAssertEqual(layout.selectedIndex(at: point(299, distance: 35)), 5)
        XCTAssertNil(layout.selectedIndex(at: point(149, distance: 35)))
        XCTAssertNil(layout.selectedIndex(at: point(301, distance: 35)))
    }
    func testActivationOptionsRoundTripAndOldSettingsUseMediumDistance() throws {
        for (value, below, above) in [("short", 21.0, 23.0), ("medium", 27.0, 29.0), ("long", 35.0, 37.0)] {
            let preferences = try JSONDecoder().decode(ThumbArcPreferences.self,
                from: Data("{\"activationDistance\":\"\(value)\"}".utf8))
            let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? [String: Any])
            XCTAssertEqual(saved["activationDistance"] as? String, value)
            let view = overlay(preferences)
            defer { view.cancel() }
            view.select(at: point(175, distance: below))
            XCTAssertNil(view.selectedIndex)
            view.select(at: point(175, distance: above))
            XCTAssertEqual(view.selectedIndex, 0)
            view.select(at: point(175, distance: 20))
            XCTAssertEqual(view.selectedIndex, 0, "Selection remains active until returning to the cancel circle")
            view.select(at: point(175, distance: 17))
            XCTAssertNil(view.selectedIndex)
        }
        let legacy = try JSONDecoder().decode(ThumbArcPreferences.self, from: Data("{}".utf8))
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        XCTAssertEqual(saved["activationDistance"] as? String, "medium")
    }
    func testSectorBoundaryHysteresisKeepsSelectionUntilCrossingTwoDegrees() {
        let view = overlay()
        defer { view.cancel() }
        for (angle, selected) in [(175.0, 0), (186, 0), (188, 1), (184, 1), (182, 0)] {
            view.select(at: point(angle, distance: 35))
            XCTAssertEqual(view.selectedIndex, selected)
        }
        view.select(at: origin)
        XCTAssertNil(view.finish(), "Returning to the cancel circle must not execute a key")
    }
    func testHighlightUsesNewSizeWithoutChangingDirectionalSelectionOrCenters() throws {
        let view = overlay()
        defer { view.cancel() }
        let keys = view.subviews.filter { $0.accessibilityLabel?.contains(" · ") == true }
        XCTAssertEqual(keys.count, 6)
        let centers = keys.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) }
        XCTAssertTrue(keys.allSatisfy { $0.bounds.size == CGSize(width: 32, height: 32) })
        view.select(at: point(195, distance: 35))
        XCTAssertEqual(view.selectedIndex, 1)
        XCTAssertEqual(keys[1].bounds.size, CGSize(width: 38, height: 38))
        XCTAssertEqual(keys.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) }, centers)
        view.select(at: point(195, distance: 230))
        XCTAssertEqual(view.finish(), .controlC)
    }
    func testMirroredAndRotatedSectorsFollowShortDirectionalTravel() {
        for left in [false, true] {
            for anchor in [origin, CGPoint(x: 580, y: 300), CGPoint(x: 300, y: 25)] {
                let layout = ThumbArcLayout(origin: anchor, bounds: CGRect(x: 0, y: 0, width: 600, height: 600),
                                            count: 6, isLeftHanded: left)
                XCTAssertEqual(layout.origin, anchor)
                for (index, center) in layout.centers.enumerated() {
                    let dx = center.x - anchor.x, dy = center.y - anchor.y
                    let distance = hypot(dx, dy)
                    let nearby = CGPoint(x: anchor.x + dx / distance * 35, y: anchor.y + dy / distance * 35)
                    XCTAssertEqual(layout.selectedIndex(at: nearby), index)
                }
            }
        }
    }
    func testLeavingArcKeepsActivationUntilReturningToCancelCircle() {
        let view = overlay()
        defer { view.cancel() }
        view.select(at: point(195, distance: 35))
        XCTAssertEqual(view.selectedIndex, 1)
        view.select(at: point(90, distance: 35))
        XCTAssertNil(view.selectedIndex)
        view.select(at: point(195, distance: 20))
        XCTAssertEqual(view.selectedIndex, 1)
        view.select(at: point(195, distance: 17))
        view.select(at: point(195, distance: 20))
        XCTAssertNil(view.selectedIndex)
    }
}
