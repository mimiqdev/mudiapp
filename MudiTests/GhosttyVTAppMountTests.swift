import GhosttyVt
import HerdrKit
import SwiftUI
import UIKit
import XCTest
@testable import Mudi

@MainActor
final class GhosttyVTAppMountTests: XCTestCase {
    func testFreshInstallKeepsSwiftTermAsDefault() async throws {
        let preferences = try JSONDecoder().decode(TerminalPreferences.self, from: Data("{}".utf8))
        XCTAssertEqual(engine(in: preferences), .swiftTerm, "Old/missing preferences must explicitly decode to SwiftTerm")
        let channel = GhosttyVTTestPTY()
        let model = RootViewModel()
        model.preferences = preferences
        let harness = Phase7TerminalScreenHarness(host: Host(displayName: "default", hostname: "default", username: "test"),
            session: SSHShellSession(connectedChannel: channel), onDisconnect: {}, settingsModel: model)
        defer { harness.close() }
        let terminal = await harness.terminal()
        XCTAssertNotNil(terminal)
        XCTAssertFalse(phase7Descendants(of: harness.controller.view).contains { $0 is GhosttyVTView })
        let attached = await ghosttyWait { (await channel.snapshot()).readers == 1 }
        XCTAssertTrue(attached)
        let snapshot = await channel.snapshot()
        XCTAssertEqual(snapshot.closes, 0)
    }

    func testExperimentalPreferenceMountsRealVTAndChangesOnlyNextMount() async throws {
        let channel = GhosttyVTTestPTY()
        await channel.emit("queued 界\u{1b}[5n")
        let model = RootViewModel()
        model.preferences = try preferences(.ghosttyVT)
        let harness = Phase7TerminalScreenHarness(host: Host(displayName: "experiment", hostname: "experiment", username: "test"),
            session: SSHShellSession(connectedChannel: channel), onDisconnect: {}, settingsModel: model)
        defer { harness.close() }
        var terminal: GhosttyVTView?
        let mounted = await ghosttyWait {
            terminal = phase7Descendants(of: harness.controller.view).compactMap { $0 as? GhosttyVTView }.first
            return terminal != nil
        }
        XCTAssertTrue(mounted, "A selected experimental engine must actually mount VT/CoreText, not a renamed SwiftTerm")
        let view = try XCTUnwrap(terminal)
        defer { view.stop() }
        let received = await ghosttyWait { (await channel.snapshot()).sent.count == 1 }
        XCTAssertTrue(received)
        XCTAssertTrue(view.screen.rows.indices.contains { view.screen.text(at: $0).contains("queued 界") })
        XCTAssertFalse(phase7Descendants(of: harness.controller.view).contains { $0 is ShellTerminalView })
        let identity = ObjectIdentifier(view.terminal)
        model.preferences = try preferences(.swiftTerm)
        try await Task.sleep(for: .milliseconds(80))
        let retained = phase7Descendants(of: harness.controller.view).compactMap { $0 as? GhosttyVTView }.first
        XCTAssertTrue(retained === view)
        XCTAssertEqual(ObjectIdentifier(view.terminal), identity)
        XCTAssertTrue(view.screen.rows.indices.contains { view.screen.text(at: $0).contains("queued 界") })
        let status = try XCTUnwrap(phase7View(with: "terminal-engine-status", in: harness.controller.view) as? UILabel)
        XCTAssertTrue(status.text?.contains("下次挂载生效") == true)
        let snapshot = await channel.snapshot()
        XCTAssertEqual(snapshot.readers, 1)
        XCTAssertEqual(snapshot.closes, 0)
        XCTAssertEqual(snapshot.sent, [Array("\u{1b}[0n".utf8)])
    }

    func testRealInitializationFailureFallsBackBeforeReadingOriginalSession() async throws {
        let channel = GhosttyVTTestPTY()
        let session = SSHShellSession(connectedChannel: channel)
        await channel.emit("retained backlog\u{1b}[5n")
        let container = TerminalViewContainer(session: session, engine: .ghosttyVT,
            experimentalConfiguration: .init(columns: 0, rows: 24), colorScheme: .dark, onError: { XCTFail($0) })
        let harness = UIPolishHarness(container, style: .dark)
        defer { harness.close() }
        await harness.settle()
        let view = try XCTUnwrap(phase7Descendants(of: harness.controller.view).compactMap { $0 as? ShellTerminalView }.first)
        XCTAssertTrue(view.session === session)
        XCTAssertFalse(phase7Descendants(of: harness.controller.view).contains { $0 is GhosttyVTView })
        let status = try XCTUnwrap(phase7View(with: "terminal-engine-status", in: harness.controller.view) as? UILabel,
                                  "A real invalidSize error must be visible, not silently swallowed")
        XCTAssertTrue(status.text?.contains("回退 SwiftTerm") == true)
        let received = await ghosttyWait { (await channel.snapshot()).sent.count == 1 }
        XCTAssertTrue(received)
        view.shortcutBar?.sendEscape()
        let sent = await ghosttyWait { (await channel.snapshot()).sent.count == 2 }
        XCTAssertTrue(sent)
        let snapshot = await channel.snapshot()
        XCTAssertEqual(snapshot.readers, 1)
        XCTAssertEqual(snapshot.closes, 0)
        XCTAssertEqual(snapshot.sent, [Array("\u{1b}[0n".utf8), [27]])
    }

    func testExperimentalVisibleViewportExcludesBarAndKeyboardFromFirstResize() async throws {
        let channel = GhosttyVTTestPTY()
        let harness = UIPolishHarness(TerminalViewContainer(session: SSHShellSession(connectedChannel: channel),
            engine: .ghosttyVT, colorScheme: .dark, onError: { XCTFail($0) }), style: .dark)
        defer { harness.close() }
        await harness.settle()
        let view = try XCTUnwrap(phase7Descendants(of: harness.controller.view).compactMap { $0 as? GhosttyVTView }.first)
        defer { view.stop() }
        let chrome = try XCTUnwrap(view.superview as? TerminalChromeView)
        let bar = try XCTUnwrap(view.shortcutBar)
        XCTAssertTrue(bar.superview === chrome)
        XCTAssertGreaterThanOrEqual(chrome.reservedBottom, bar.preferredHeight)
        XCTAssertLessThanOrEqual(view.frame.maxY, bar.frame.minY + 0.5)
        let first = await ghosttyWait { !(await channel.snapshot()).sizes.isEmpty }
        XCTAssertTrue(first)
        let initial = await channel.snapshot()
        XCTAssertEqual(initial.sizes.first, view.screen.size,
                       "Initial mount must not emit an old full-height grid under the persistent bar")
        let keyboard = CGRect(x: 0, y: harness.controller.view.bounds.midY,
                              width: harness.controller.view.bounds.width, height: harness.controller.view.bounds.height / 2)
        view.updateShortcutBarOffset(keyboardFrameEnd: keyboard)
        chrome.layoutIfNeeded()
        view.layoutIfNeeded()
        let resized = await ghosttyWait { (await channel.snapshot()).sizes.last == view.screen.size }
        XCTAssertTrue(resized)
        XCTAssertEqual(view.screen.size, GhosttyVTGridGeometry.size(viewport: view.bounds.size, cell: view.cellSize))
        XCTAssertLessThanOrEqual(view.frame.maxY, bar.frame.minY + 0.5)
        XCTAssertLessThan(view.screen.size.rows, initial.sizes.first?.rows ?? 0)
    }

    func testStoredOptInAndSettingsExplainDeferredApplication() async throws {
        let name = "GhosttyVTPreferences.\(UUID())"
        defer { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        let defaults = UserDefaults(suiteName: name)!
        let store = UserDefaultsPreferencesStore(defaults: defaults)
        try await store.save(try preferences(.ghosttyVT))
        let restored = try await store.load()
        XCTAssertEqual(engine(in: restored), .ghosttyVT)
        let model = RootViewModel(preferencesStore: store)
        await model.loadPreferences()
        let harness = UIPolishHarness(NavigationStack { SettingsView(model: model) }, style: .dark)
        defer { harness.close() }
        await harness.settle()
        let marker = try XCTUnwrap(phase7View(with: "terminal-engine-picker", in: harness.controller.view))
        XCTAssertTrue(marker.accessibilityLabel?.contains("下次挂载生效") == true)
    }

    private func preferences(_ engine: TerminalEnginePreference) throws -> TerminalPreferences {
        try JSONDecoder().decode(TerminalPreferences.self, from: Data("{\"terminalEngine\":\"\(engine.rawValue)\"}".utf8))
    }
    private func engine(in preferences: TerminalPreferences) -> TerminalEnginePreference? {
        Mirror(reflecting: preferences).children.first { $0.label == "terminalEngine" }?.value as? TerminalEnginePreference
    }
}
