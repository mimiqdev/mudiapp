import Foundation
import HerdrKit
import UIKit
import XCTest
@testable import Mudi

@MainActor
final class UIPolishInteractionTests: XCTestCase {
    func testSearchMatchesRealHierarchyAndFilteringRetainsPaneIdentity() {
        let catalog = PanePickerCatalog(host: PreviewData.hosts[0], snapshot: PreviewData.snapshot)
        XCTAssertEqual(Set(catalog.matching(query: "QING", filter: .all).map(\.pane.id)), ["pane-agent", "pane-reviewer"])
        XCTAssertEqual(catalog.matching(query: "coding", filter: .working).map(\.pane.id), ["pane-agent"])
        XCTAssertEqual(catalog.matching(query: "reviewer", filter: .waiting).map(\.pane.id), ["pane-reviewer"])
        XCTAssertEqual(catalog.matching(query: "desktop.local", filter: .all).count, 2)
        XCTAssertTrue(catalog.matching(query: "no match", filter: .all).isEmpty)
        XCTAssertEqual(PreviewData.snapshot.sessions[0].workspaces[0].tabs[0].panes.count, 2)
    }

    func testFavoritesAndRecentsPersistWithHostScopedIdentity() throws {
        let name = "UIPolishTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let first = UUID(), second = UUID()
        let history = PanePickerHistory(defaults: defaults)
        history.toggleFavorite(hostID: first, paneID: "p1")
        history.recordSelection(hostID: first, paneID: "p1")
        history.recordSelection(hostID: first, paneID: "p2")
        history.recordSelection(hostID: first, paneID: "p1")
        let restored = PanePickerHistory(defaults: defaults)
        XCTAssertTrue(restored.isFavorite(hostID: first, paneID: "p1"))
        XCTAssertFalse(restored.isFavorite(hostID: second, paneID: "p1"))
        XCTAssertEqual(restored.recentPaneIDs(hostID: first), ["p1", "p2"])
        XCTAssertTrue(restored.recentPaneIDs(hostID: second).isEmpty)
    }

    func testArcHitTestingCancelsAtOriginAndMirrorsHandedness() {
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 600)
        let origin = CGPoint(x: 300, y: 300)
        let right = ThumbArcLayout(origin: origin, bounds: bounds, count: 6, isLeftHanded: false)
        let left = ThumbArcLayout(origin: origin, bounds: bounds, count: 6, isLeftHanded: true)
        XCTAssertNil(right.selectedIndex(at: origin))
        for index in 0..<6 {
            XCTAssertEqual(right.selectedIndex(at: right.centers[index]), index)
            XCTAssertEqual(right.centers[index].x + left.centers[index].x, 600, accuracy: 0.5)
            XCTAssertEqual(right.centers[index].y, left.centers[index].y, accuracy: 0.5)
        }
    }

    func testArcTargetsStayInsideCompactAndSplitViewBounds() {
        for bounds in [CGRect(x: 0, y: 0, width: 320, height: 380), CGRect(x: 0, y: 0, width: 700, height: 260)] {
            for origin in [CGPoint(x: 2, y: 2), CGPoint(x: bounds.maxX - 2, y: bounds.maxY - 2)] {
                for left in [false, true] {
                    let layout = ThumbArcLayout(origin: origin, bounds: bounds, count: 6, isLeftHanded: left)
                    XCTAssertEqual(layout.centers.count, 6)
                    for center in layout.centers {
                        XCTAssertTrue(bounds.contains(CGRect(x: center.x - 21, y: center.y - 21, width: 42, height: 42)))
                    }
                    XCTAssertNil(layout.selectedIndex(at: origin))
                }
            }
        }
    }

    func testArcSelectionKeepsTargetGeometryStable() {
        let overlay = MudiThumbArcOverlay()
        overlay.frame = CGRect(x: 0, y: 0, width: 440, height: 956)
        let preferences = ThumbArcPreferences()
        overlay.begin(origin: CGPoint(x: 330, y: 590), preferences: preferences)
        defer { overlay.cancel() }
        let keys = overlay.subviews.filter { $0.accessibilityLabel?.contains(" · ") == true }
        XCTAssertEqual(keys.count, preferences.actions.count)
        let frames = keys.map(\.frame)
        for index in keys.indices {
            overlay.select(at: CGPoint(x: frames[index].midX, y: frames[index].midY))
            XCTAssertEqual(overlay.selectedIndex, index)
            XCTAssertEqual(keys.map(\.frame), frames, "Selection must not enlarge or move any target")
        }
        XCTAssertEqual(overlay.finish(), preferences.actions.last)
    }

    func testArcPreferenceSanitizationCapsSlotsAndKeepsUniqueActions() throws {
        let json = #"{"actions":["escape","escape","futureUnknownAction","controlC","shiftTab","cursorUp","paste","jumpTo","tab"]}"#
        let value = try JSONDecoder().decode(ThumbArcPreferences.self, from: Data(json.utf8))
        XCTAssertEqual(value.actions.count, 6)
        XCTAssertEqual(Set(value.actions).count, 6)
        XCTAssertEqual(value.actions.first, .escape)
    }

    func testDynamicPaletteResolvesOnTheBackgroundRenderingExecutor() async throws {
        let color = MudiPalette.canvasUI
        let components = await Task.detached {
            color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)).cgColor.components
        }.value
        XCTAssertEqual(try XCTUnwrap(components).prefix(3).map { Int(($0 * 255).rounded()) }, [10, 10, 10])
    }

    func testDPadCornerChoicePersistsAndUsesTheTerminalInputPath() throws {
        let keys = ["dev.mudi.mobile.dpad-corner-left", "dev.mudi.mobile.dpad-corner-right"]
        let defaults = UserDefaults.standard
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        } }
        keys.forEach { defaults.removeObject(forKey: $0) }
        let terminal = ShellTerminalView(frame: .zero)
        defer { terminal.stop() }
        let recorder = Phase7TerminalInputRecorder()
        terminal.terminalDelegate = recorder
        let overlay = try XCTUnwrap(terminal.shortcutBar?.dpadOverlay)
        let left = try XCTUnwrap(phase7View(with: "terminal-dpad-backspace", in: overlay) as? UIButton)
        let right = try XCTUnwrap(phase7View(with: "terminal-dpad-clearScreen", in: overlay) as? UIButton)
        overlay.setCornerCommand(.pageUp, index: 0)
        overlay.setCornerCommand(.pageDown, index: 1)
        left.sendActions(for: .touchUpInside)
        right.sendActions(for: .touchUpInside)
        XCTAssertEqual(recorder.sentBytes, [[0x1b, 0x5b, 0x35, 0x7e], [0x1b, 0x5b, 0x36, 0x7e]])
        let restored = MudiTerminalDPadOverlay()
        let corners = phase7Descendants(of: restored).compactMap { $0 as? UIButton }
        XCTAssertTrue(corners.contains { $0.accessibilityLabel == "Page Up" })
        XCTAssertTrue(corners.contains { $0.accessibilityLabel == "Page Down" })
    }

    func testArcAndComposeSendThroughTheLiveSessionInputPath() async throws {
        let channel = UIPolishRecordingChannel()
        let terminal = ShellTerminalView(frame: .zero)
        let session = SSHShellSession(connectedChannel: channel)
        terminal.start(session: session, onError: { _ in })
        defer { terminal.stop() }
        terminal.executeThumbArcAction(.controlC)
        terminal.executeThumbArcAction(.shiftTab)
        let bar = try XCTUnwrap(terminal.shortcutBar)
        terminal.feed(text: "\u{1b}[?2004h")
        bar.sendComposedText("first\nsecond")
        terminal.feed(text: "\u{1b}[?2004l")
        bar.sendComposedText("plain")
        for _ in 0..<100 {
            if await channel.sent().count == 4 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let sent = await channel.sent()
        XCTAssertEqual(sent.count, 4)
        XCTAssertTrue(sent.contains(Array("plain".utf8)))
        XCTAssertTrue(sent.contains([0x03]))
        XCTAssertTrue(sent.contains([0x1b, 0x5b, 0x5a]))
        XCTAssertTrue(sent.contains(Array("\u{1b}[200~first\nsecond\u{1b}[201~".utf8)))
    }
}

private actor UIPolishRecordingChannel: PTYChannel {
    private var values: [[UInt8]] = []
    func send(_ bytes: [UInt8]) async throws { values.append(bytes) }
    func resize(columns: Int, rows: Int) async throws {}
    func close() async {}
    func sent() -> [[UInt8]] { values }
}
