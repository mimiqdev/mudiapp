import Foundation
import HerdrKit
import UIKit
import XCTest
@testable import Mudi

@MainActor
final class UIPolishInteractionTests: XCTestCase {
    func testComposerReplacesBarAndRequiresConfirmationForChangedLongText() throws {
        let defaults = UserDefaults.standard, key = "com.mimiqdev.mudi.composer-records"
        let saved = defaults.object(forKey: key)
        defer { if let saved { defaults.set(saved, forKey: key) } else { defaults.removeObject(forKey: key) } }
        let terminal = ShellTerminalView(frame: .zero)
        defer { terminal.stop() }
        let recorder = Phase7TerminalInputRecorder()
        terminal.terminalDelegate = recorder
        terminal.feed(text: "\u{1b}[?2004h")
        let bar = try XCTUnwrap(terminal.shortcutBar)
        bar.frame = CGRect(x: 0, y: 0, width: 390, height: 48)
        bar.openCompose()
        let input = try XCTUnwrap(phase7View(with: "terminal-compose-input", in: bar) as? UITextView,
                                 "Composer must be inline in the shortcut bar")
        let send = try XCTUnwrap(phase7View(with: "terminal-compose-send", in: bar) as? UIButton)
        let text = (1...21).map { "line \($0)" }.joined(separator: "\n")
        input.text = text
        input.delegate?.textViewDidChange?(input)
        send.sendActions(for: .touchUpInside)
        XCTAssertTrue(recorder.sentBytes.isEmpty)
        XCTAssertTrue(send.title(for: .normal)?.contains("21") == true)
        input.text = text + " edited"
        input.delegate?.textViewDidChange?(input)
        send.sendActions(for: .touchUpInside)
        XCTAssertTrue(recorder.sentBytes.isEmpty, "Editing must invalidate the previous confirmation")
        send.sendActions(for: .touchUpInside)
        XCTAssertEqual(recorder.sentBytes, [Array("\u{1b}[200~\(text) edited\u{1b}[201~\r".utf8)])
    }

    func testInlineComposerRidesCandidateHeightAndRestoresScrollableBar() async throws {
        let terminal = ShellTerminalView(frame: .zero)
        let chrome = TerminalChromeView(terminalView: terminal)
        let harness = Phase7TerminalViewHarness(terminalView: terminal, chromeView: chrome)
        defer { terminal.stop(); harness.close() }
        let bar = try XCTUnwrap(terminal.shortcutBar)
        harness.window.layoutIfNeeded()
        bar.openCompose()
        let card = try XCTUnwrap(bar.composer)
        card.setText((1...30).map { "第 \($0) 行：中文输入与自动增高" }.joined(separator: "\n"))
        for height in [300.0, 348.0] {
            let end = CGRect(x: 0, y: harness.window.bounds.maxY - height, width: harness.window.bounds.width, height: height)
            terminal.updateShortcutBarOffset(keyboardFrameEnd: end)
            harness.window.layoutIfNeeded()
            XCTAssertEqual(bar.frame.maxY, chrome.convert(end, from: nil).minY, accuracy: 0.5)
            XCTAssertLessThanOrEqual(card.input.bounds.height, (card.input.font?.lineHeight ?? 22) * 6 + 8.5)
            XCTAssertTrue(card.input.isScrollEnabled)
            XCTAssertEqual(chrome.reservedBottom, chrome.bounds.maxY - bar.frame.minY, accuracy: 0.5)
        }
        card.toolbarScroll.setContentOffset(CGPoint(x: 80, y: 0), animated: false)
        bar.closeCompose()
        bar.openCompose()
        XCTAssertEqual(card.toolbarScroll.contentOffset.x, 0, accuracy: 0.1)
        XCTAssertEqual(try XCTUnwrap(card.toolbarScroll.subviews.compactMap { $0 as? UIStackView }.first)
            .arrangedSubviews.last?.accessibilityIdentifier, "terminal-compose-clear")
        bar.closeCompose()
        terminal.updateShortcutBarOffset(keyboardFrameEnd: CGRect(x: 0, y: harness.window.bounds.maxY, width: 390, height: 0))
        harness.window.layoutIfNeeded()
        XCTAssertEqual(bar.bounds.height, 48, accuracy: 0.5)
        XCTAssertFalse(bar.scrollView.isHidden)
    }

    func testInlineComposerYieldsFocusWhenTerminalInputIsBlocked() throws {
        let terminal = ShellTerminalView(frame: .zero)
        let chrome = TerminalChromeView(terminalView: terminal)
        let harness = Phase7TerminalViewHarness(terminalView: terminal, chromeView: chrome)
        defer { terminal.stop(); harness.close() }
        let bar = try XCTUnwrap(terminal.shortcutBar)
        harness.window.layoutIfNeeded()
        bar.openCompose()
        let input = try XCTUnwrap(bar.composer?.input)
        XCTAssertTrue(input.isFirstResponder)
        terminal.updateInputFocus(isAllowed: false)
        XCTAssertFalse(input.isFirstResponder, "Hidden or blocked terminal must release Composer keyboard focus")
        terminal.updateInputFocus(isAllowed: true)
        bar.openCompose()
        XCTAssertTrue(input.isFirstResponder)
        terminal.stop()
        XCTAssertFalse(input.isFirstResponder, "Terminal teardown must release Composer input")
    }

    func testShortcutOrderAndControlsHaveIndependent44PointTargets() throws {
        let terminal = ShellTerminalView(frame: .zero)
        defer { terminal.stop() }
        let bar = try XCTUnwrap(terminal.shortcutBar)
        bar.frame = CGRect(x: 0, y: 0, width: 320, height: 48)
        bar.layoutIfNeeded()
        XCTAssertEqual(bar.stackView.arrangedSubviews.compactMap(\.accessibilityIdentifier).filter { $0.hasPrefix("terminal-shortcut-") },
                       ["escape", "tab", "control", "dpad", "compose", "paste", "history"].map { "terminal-shortcut-" + $0 })
        for button in bar.shortcutButtons + [bar.dismissKeyboardButton] {
            XCTAssertGreaterThanOrEqual(button.bounds.width, 44)
            XCTAssertGreaterThanOrEqual(button.bounds.height, 44)
        }
        bar.toggleControl()
        for button in phase7Descendants(of: bar.comboPopup).compactMap({ $0 as? UIButton }) {
            XCTAssertGreaterThanOrEqual(button.bounds.width, 44)
            XCTAssertGreaterThanOrEqual(button.bounds.height, 44)
        }
        bar.toggleDPad()
        let lock = try XCTUnwrap(phase7View(with: "terminal-dpad-lock", in: bar))
        XCTAssertGreaterThanOrEqual(lock.bounds.width, 44)
        XCTAssertGreaterThanOrEqual(lock.bounds.height, 44)
    }

    func testDPadRetainsMovedPositionAndStaysInsideShortContainer() throws {
        let defaults = UserDefaults.standard
        let key = "com.mimiqdev.mudi.dpad-relative-position"
        let saved = defaults.object(forKey: key)
        defaults.removeObject(forKey: key)
        defer { if let saved { defaults.set(saved, forKey: key) } else { defaults.removeObject(forKey: key) } }
        let terminal = ShellTerminalView(frame: .zero)
        defer { terminal.stop() }
        let bar = try XCTUnwrap(terminal.shortcutBar)
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 440, height: 650))
        container.addSubview(bar)
        bar.frame = CGRect(x: 0, y: 602, width: 440, height: 48)
        bar.toggleDPad()
        bar.moveDPadOverlay(translation: CGPoint(x: 40, y: -100))
        bar.layoutIfNeeded()
        let moved = bar.dpadOverlay.frame
        bar.toggleDPad()
        bar.toggleDPad()
        bar.layoutIfNeeded()
        XCTAssertEqual(bar.dpadOverlay.frame, moved, "Reopening must preserve the dragged position")
        container.bounds.size = CGSize(width: 650, height: 240)
        bar.frame = CGRect(x: 0, y: 192, width: 650, height: 48)
        bar.setNeedsLayout(); bar.layoutIfNeeded()
        let frame = bar.dpadOverlay.convert(bar.dpadOverlay.bounds, to: container)
        XCTAssertTrue(container.bounds.contains(frame), "Rotation must bring the whole D-Pad into the safe container")
        XCTAssertLessThanOrEqual(frame.maxY, bar.frame.minY)
    }

    func testTypographyScalesWithAccessibilityContentSize() {
        var normal: CGFloat = 0, enlarged: CGFloat = 0
        UITraitCollection(preferredContentSizeCategory: .large).performAsCurrent {
            normal = MudiTypography.uiFont(16).pointSize
        }
        UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge).performAsCurrent {
            enlarged = MudiTypography.uiFont(16).pointSize
        }
        XCTAssertGreaterThan(enlarged, normal * 1.5)
    }

    func testLightFloatingArcRestoresLightOutlineAndSizeAfterCancelling() throws {
        let overlay = MudiThumbArcOverlay()
        overlay.overrideUserInterfaceStyle = .light
        overlay.frame = CGRect(x: 0, y: 0, width: 440, height: 650)
        overlay.begin(origin: CGPoint(x: 330, y: 420), preferences: ThumbArcPreferences())
        defer { overlay.cancel() }
        let key = try XCTUnwrap(overlay.subviews.first { $0.accessibilityLabel?.contains(" · ") == true })
        XCTAssertEqual(try XCTUnwrap(key.layer.borderColor).alpha, 0.10, accuracy: 0.001)
        XCTAssertEqual(key.layer.shadowOpacity, 0.14, accuracy: 0.001)
        XCTAssertEqual(key.bounds.size, CGSize(width: 32, height: 32))
        overlay.select(at: CGPoint(x: key.frame.midX, y: key.frame.midY))
        XCTAssertEqual(key.bounds.size, CGSize(width: 38, height: 38))
        overlay.select(at: CGPoint(x: 330, y: 420))
        XCTAssertEqual(try XCTUnwrap(key.layer.borderColor).alpha, 0.10, accuracy: 0.001,
                       "Returning to origin must restore the light outline token")
        XCTAssertEqual(key.bounds.size, CGSize(width: 32, height: 32))
    }

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
                        XCTAssertTrue(bounds.contains(CGRect(x: center.x - 19, y: center.y - 19, width: 38, height: 38)))
                    }
                    XCTAssertNil(layout.selectedIndex(at: origin))
                }
            }
        }
    }

    func testArcSelectionEnlargesHighlightAroundStableCenters() {
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
            XCTAssertEqual(keys.map(\.center), frames.map { CGPoint(x: $0.midX, y: $0.midY) })
            for (keyIndex, key) in keys.enumerated() {
                let size: CGFloat = keyIndex == index ? 38 : 32
                XCTAssertEqual(key.bounds.size, CGSize(width: size, height: size))
            }
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
        let keys = ["com.mimiqdev.mudi.dpad-corner-left", "com.mimiqdev.mudi.dpad-corner-right"]
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
