import HerdrKit
import SwiftUI
import UIKit
import XCTest
@testable import Mudi

@MainActor
final class UIPolishTests: XCTestCase {
    func testHostsUseFigmaCanvasInBothAppearancesAndKeepHostAction() async throws {
        let host = phase4Host()
        for (style, expected) in [(UIUserInterfaceStyle.dark, [10, 10, 10]), (.light, [250, 250, 247])] {
            var selected: Host.ID?
            let view = NavigationStack {
                HostListView(
                    hosts: [host], connectionState: .idle,
                    connectingHostID: nil, showsConnectCancel: false,
                    errorMessage: nil, onConnect: { selected = $0.id },
                    onReconnect: {}, onAdd: {}, onEdit: { _ in }, onDelete: { _ in }
                )
            }
            let harness = UIPolishHarness(view, style: style)
            defer { harness.close() }
            await harness.settle()
            let action = try XCTUnwrap(phase7View(with: "host-connect-\(host.id.uuidString)", in: harness.controller.view))
            XCTAssertTrue(phase7Activate(action))
            XCTAssertEqual(selected, host.id)
            let screenshot = harness.screenshot()
            add(XCTAttachment(image: screenshot))
            let rgb = try sample(screenshot, at: CGPoint(x: 16, y: harness.controller.view.bounds.height - 80))
            for component in 0..<3 { XCTAssertEqual(rgb[component], expected[component], accuracy: 2) }
        }
    }

    func testPickerOffersSearchAndStateFiltersWithoutLosingCurrentPane() async throws {
        let session = try XCTUnwrap(PreviewData.snapshot.sessions.first)
        let pane = try XCTUnwrap(session.workspaces.first?.tabs.first?.panes.first)
        let state = PanePickerState(
            host: phase4Host(), origin: .terminal, snapshot: PreviewData.snapshot,
            attachedTerminal: PanePickerAttachedTerminal(host: phase4Host(), session: session, pane: pane)
        )
        let harness = UIPolishHarness(PanePickerView(
            state: state, onDismiss: {}, onRefresh: {}, onCreateWorkspace: {},
            isCreatingWorkspace: false, onSelectPane: { _ in }, onSelectOrdinaryTerminal: {}, onAppear: {}
        ))
        defer { harness.close() }
        await harness.settle()
        XCTAssertNotNil(phase7View(with: "pane-picker-search", in: harness.controller.view))
        for filter in ["all", "waiting", "working", "done"] {
            XCTAssertNotNil(phase7View(with: "pane-picker-filter-\(filter)", in: harness.controller.view))
        }
        add(XCTAttachment(image: harness.screenshot()))
    }

    func testShortcutBarHasScrollableHistoryComposeAndPinnedNavigation() throws {
        let terminal = ShellTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        defer { terminal.stop() }
        let bar = try XCTUnwrap(terminal.shortcutBar)
        bar.frame = CGRect(x: 0, y: 0, width: 320, height: 48)
        bar.layoutIfNeeded()
        for id in ["history", "compose", "jump-to", "dismiss-keyboard"] {
            XCTAssertNotNil(phase7View(with: "terminal-shortcut-\(id)", in: bar), id)
        }
        XCTAssertTrue(phase7Descendants(of: bar).contains { $0 is UIScrollView })
        for id in ["jump-to", "dismiss-keyboard"] {
            let button = try XCTUnwrap(phase7View(with: "terminal-shortcut-\(id)", in: bar))
            let frame = button.convert(button.bounds, to: bar)
            XCTAssertTrue(bar.bounds.contains(frame), "Pinned action must remain visible: \(id)")
        }
    }

    func testDPadLockKeepsPositionButDoesNotDisableKeys() throws {
        let terminal = ShellTerminalView(frame: .zero)
        defer { terminal.stop() }
        let bar = try XCTUnwrap(terminal.shortcutBar)
        bar.frame = CGRect(x: 0, y: 0, width: 390, height: 48)
        bar.toggleDPad()
        bar.layoutIfNeeded()
        let lock = try XCTUnwrap(phase7View(with: "terminal-dpad-lock", in: bar) as? UIButton)
        lock.sendActions(for: .touchUpInside)
        let before = bar.dpadOverlay.frame
        bar.moveDPadOverlay(translation: CGPoint(x: 50, y: -100))
        bar.layoutIfNeeded()
        XCTAssertEqual(bar.dpadOverlay.frame, before)
        let arrows = phase7Descendants(of: bar.dpadOverlay).compactMap { $0 as? UIButton }
            .filter { ["terminal-dpad-up", "terminal-dpad-down", "terminal-dpad-left", "terminal-dpad-right"].contains($0.accessibilityIdentifier ?? "") }
        XCTAssertEqual(arrows.count, 4)
        XCTAssertTrue(arrows.allSatisfy(\.isEnabled))
    }

    func testDoubleTapDragIsInstalledWithoutReplacingTextSelection() {
        let terminal = ShellTerminalView(frame: .zero)
        defer { terminal.stop() }
        let longPresses = (terminal.gestureRecognizers ?? []).compactMap { $0 as? UILongPressGestureRecognizer }
        XCTAssertTrue(longPresses.contains { $0.numberOfTapsRequired == 1 }, "Second-tap hold/drag must open the arc")
        XCTAssertTrue(longPresses.contains { $0.numberOfTapsRequired == 0 }, "Text selection keeps its original single long press")
    }

    func testArcPreferencesRoundTripAndOldPreferencesRemainCompatible() throws {
        let json = #"{"fontSize":18,"thumbArc":{"actions":["escape","controlC","shiftTab"],"isLeftHanded":true,"hapticsEnabled":false}}"#
        let preferences = try JSONDecoder().decode(TerminalPreferences.self, from: Data(json.utf8))
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? [String: Any])
        let arc = try XCTUnwrap(saved["thumbArc"] as? [String: Any])
        XCTAssertEqual(arc["actions"] as? [String], ["escape", "controlC", "shiftTab"])
        XCTAssertEqual(arc["isLeftHanded"] as? Bool, true)
        XCTAssertEqual(arc["hapticsEnabled"] as? Bool, false)
        XCTAssertEqual(preferences.fontSize, 18)
        let old = try JSONDecoder().decode(TerminalPreferences.self, from: Data("{}".utf8))
        XCTAssertEqual(old.themeSelection, TerminalThemeRegistry.defaultSelection)
    }

    private func sample(_ image: UIImage, at point: CGPoint) throws -> [Int] {
        let cg = try XCTUnwrap(image.cgImage)
        let x = Int(point.x * image.scale), y = Int(point.y * image.scale)
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let pixel = try XCTUnwrap(cg.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return bytes.prefix(3).map(Int.init)
    }
}

@MainActor
final class UIPolishHarness<Content: View> {
    let window: UIWindow
    let controller: UIHostingController<Content>
    init(_ view: Content, style: UIUserInterfaceStyle = .dark) {
        window = Phase7TerminalScreenHarness.makeWindow()
        window.overrideUserInterfaceStyle = style
        controller = UIHostingController(rootView: view)
        controller.overrideUserInterfaceStyle = style
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        controller.loadViewIfNeeded()
        Phase7TerminalScreenHarness.kickAppearance(of: controller)
    }
    func settle() async {
        try? await Task.sleep(for: .milliseconds(300))
        controller.view.layoutIfNeeded()
    }
    func screenshot() -> UIImage {
        UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
    }
    func close() {
        phase7Descendants(of: controller.view).compactMap { $0 as? ShellTerminalView }.forEach { $0.stop() }
        controller.view.removeFromSuperview()
        window.rootViewController = nil
        window.isHidden = true
    }
}
