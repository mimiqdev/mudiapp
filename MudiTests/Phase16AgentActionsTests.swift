import Foundation
import HerdrKit
import UIKit
import XCTest
@testable import Mudi

/// Exercise the real RootView → TerminalScreen → shortcut bar → PTY path,
/// rather than testing a preset catalog that the screen never consumes.
@MainActor
final class Phase16AgentActionsTests: XCTestCase {
    func testPiPaneAgentPresentsAgentActionsPanelWithBuiltInPresets() async throws {
        let fixture = try Phase16TerminalFixture()
        defer { fixture.close() }
        let terminal = try await fixture.terminal()
        let panel = try openPanel(on: terminal)

        XCTAssertFalse(panel.isHidden)
        XCTAssertEqual(presetLabel(in: panel)?.text, "当前预设：Pi")
        XCTAssertEqual(try presetPicker(in: panel).selectedSegmentIndex, 1)
        let expected = ["reload", "compact", "resume", "tree"]
        for id in expected {
            XCTAssertNotNil(phase7View(with: "terminal-agent-action-" + id, in: panel), id)
        }
        for id in ["model", "thinking", "tools", "thinking-blocks", "interrupt"] {
            XCTAssertNil(phase7View(with: "terminal-agent-action-" + id, in: panel))
        }

        fixture.harness.window.layoutIfNeeded()
        let bar = try XCTUnwrap(terminal.shortcutBar)
        let container = try XCTUnwrap(bar.superview)
        let visibleFrame = panel.convert(panel.bounds, to: container)
        XCTAssertGreaterThan(visibleFrame.height, 0)
        XCTAssertGreaterThanOrEqual(visibleFrame.minY, container.safeAreaInsets.top - 0.5)
        XCTAssertGreaterThanOrEqual(visibleFrame.minX, 0)
        XCTAssertLessThanOrEqual(visibleFrame.maxX, container.bounds.width)
        let modelButton = try action("reload", in: panel)
        let center = CGPoint(x: modelButton.bounds.midX, y: modelButton.bounds.midY)
        let point = modelButton.convert(center, to: fixture.harness.window)
        let hit = fixture.harness.window.hitTest(point, with: nil)
        XCTAssertTrue(hit === modelButton || hit?.isDescendant(of: modelButton) == true,
                      "The floating panel must receive real touches outside the bar's bounds")
    }

    func testMissingOrUnsupportedAgentTypeFallsBackToGenericOperations() async throws {
        let fixture = try Phase16TerminalFixture()
        defer { fixture.close() }
        let terminal = try await fixture.terminal()
        let panel = try openPanel(on: terminal)

        for name in [nil, "codex", "pi-helper", "claude-helper"] as [String?] {
            var pane = fixture.pane
            pane.agent = name.map { Agent(name: $0, state: .idle) }
            // A Pi-looking title must not substitute for official agent data.
            pane.title = "π - pi terminal"
            fixture.setPane(pane)
            let refreshed = await fixture.harness.waitUntil {
                self.presetLabel(in: panel)?.text == "当前预设：通用"
            }
            XCTAssertTrue(refreshed)
            XCTAssertEqual(try presetPicker(in: panel).selectedSegmentIndex, 0)
            XCTAssertNotNil(phase7View(with: "terminal-agent-action-shift-tab", in: panel))
            XCTAssertNil(phase7View(with: "terminal-agent-action-model", in: panel))
            XCTAssertNil(phase7View(with: "terminal-agent-action-reload", in: panel))
        }
    }

    func testManualPresetSelectionPersistsWithinPaneContext() async throws {
        let fixture = try Phase16TerminalFixture()
        defer { fixture.close() }
        let terminal = try await fixture.terminal()
        let panel = try openPanel(on: terminal)
        let picker = try presetPicker(in: panel)
        picker.selectedSegmentIndex = 0
        picker.sendActions(for: .valueChanged)
        XCTAssertEqual(presetLabel(in: panel)?.text, "当前预设：通用")

        var refreshed = fixture.pane
        refreshed.title = "refreshed title"
        refreshed.agent = Agent(name: "pi", state: .working)
        fixture.setPane(refreshed)
        await settle()
        XCTAssertEqual(presetLabel(in: panel)?.text, "当前预设：通用",
                       "A status/title refresh must not undo a manual choice")

        let other = Pane(id: "phase16:other", title: "other", agent: refreshed.agent)
        fixture.setPane(other)
        let otherTerminal = try await fixture.terminal(excluding: terminal)
        let otherPanel = try openPanel(on: otherTerminal)
        XCTAssertEqual(presetLabel(in: otherPanel)?.text, "当前预设：Pi",
                       "A new pane must use its own recommendation")

        var unknown = other
        unknown.agent = nil
        fixture.setPane(unknown)
        let updated = await fixture.harness.waitUntil {
            self.presetLabel(in: otherPanel)?.text == "当前预设：通用"
        }
        XCTAssertTrue(updated)
        let otherPicker = try presetPicker(in: otherPanel)
        otherPicker.selectedSegmentIndex = 1
        otherPicker.sendActions(for: .valueChanged)
        XCTAssertEqual(presetLabel(in: otherPanel)?.text, "当前预设：Pi",
                       "Manual built-in presets remain available without detection")
        otherPicker.selectedSegmentIndex = 2
        otherPicker.sendActions(for: .valueChanged)
        XCTAssertEqual(presetLabel(in: otherPanel)?.text, "当前预设：Claude Code")
    }

    func testClaudeCodePanePresentsVerifiedActionsAndCommands() async throws {
        let fixture = try Phase16TerminalFixture()
        defer { fixture.close() }
        var pane = fixture.pane
        pane.agent = Agent(name: "Claude Code", state: .working)
        fixture.setPane(pane)
        let terminal = try await fixture.terminal()
        let panel = try openPanel(on: terminal)
        let ready = await fixture.harness.waitUntil {
            self.presetLabel(in: panel)?.text == "当前预设：Claude Code"
        }
        XCTAssertTrue(ready)
        XCTAssertEqual(try presetPicker(in: panel).selectedSegmentIndex, 2)
        let expected = ["model", "context", "compact", "resume", "usage", "rewind", "clear", "tasks"]
        for id in expected { XCTAssertNotNil(phase7View(with: "terminal-agent-action-" + id, in: panel), id) }
        for id in ["interrupt", "transcript", "permissions", "control-c", "shift-tab"] {
            XCTAssertNil(phase7View(with: "terminal-agent-action-" + id, in: panel), id)
        }
        try action("rewind", in: panel).sendActions(for: .touchUpInside)
        let text = try XCTUnwrap(phase7View(with: "terminal-agent-command-text", in: panel) as? UILabel)
        XCTAssertEqual(text.text, "/rewind")
        let warning = try XCTUnwrap(phase7View(with: "terminal-agent-command-warning", in: panel) as? UILabel)
        XCTAssertTrue(warning.text?.contains("回滚代码和/或对话") == true)
        try button("terminal-agent-command-cancel", in: panel).sendActions(for: .touchUpInside)
        let sent = await fixture.channel.sent()
        XCTAssertEqual(sent, [])
    }

    func testManualModelConfigurationPersistsAndRequiresConfirmation() async throws {
        let saved = TerminalAgentPreset.pi.configuredModels
        defer { TerminalAgentPreset.pi.saveModels(saved.joined(separator: "\n")) }
        let fixture = try Phase16TerminalFixture()
        defer { fixture.close() }
        let terminal = try await fixture.terminal()
        let panel = try openPanel(on: terminal)
        let editor = AgentModelEditorController(preset: .pi)
        editor.loadViewIfNeeded()
        editor.input.text = "/model anthropic/test-model\ninvalid;command\nanthropic/test-model"
        editor.save()
        let list = AgentModelListController(preset: .pi)
        list.loadViewIfNeeded()
        XCTAssertEqual(list.tableView(list.tableView, numberOfRowsInSection: 0), 1)
        XCTAssertNil(phase7View(with: "terminal-agent-model-input", in: panel))
        XCTAssertNil(phase7View(with: "terminal-agent-action-configured-model-anthropic/test-model", in: panel))
        XCTAssertEqual(TerminalAgentPreset.pi.configuredModels, ["anthropic/test-model"])
        (panel as? MudiAgentActionsPanel)?.onAction?("configured-model-anthropic/test-model")
        let before = await fixture.channel.sent()
        XCTAssertEqual(before, [])
        try button("terminal-agent-command-confirm", in: panel).sendActions(for: .touchUpInside)
        try await fixture.waitForInputCount(2)
        let after = await fixture.channel.sent()
        XCTAssertEqual(after, [Array("/model anthropic/test-model".utf8), [13]])
        XCTAssertTrue(panel.isHidden)
    }

    func testQuickModelMigrationAndScopeFilteringPreserveRawCommands() throws {
        let suite = "quick-model-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["anthropic/test"], forKey: "agent-models-1")
        let store = QuickModelStore(defaults: defaults)
        XCTAssertEqual(store.models.map(\.command), ["/model anthropic/test"])
        XCTAssertTrue(store.models[0].applies(to: "pi"))
        XCTAssertFalse(store.models[0].applies(to: "codex"))
        store.models.append(QuickModel(name: "Any", command: "/model custom:id --flag", scopes: []))
        let restored = QuickModelStore(defaults: defaults)
        XCTAssertEqual(restored.models.count, 2)
        XCTAssertTrue(restored.models[1].applies(to: nil))
        XCTAssertEqual(restored.models[1].command, "/model custom:id --flag")
    }

    func testGenericKeyActionSendsBytesAndDismissesPanel() throws {
        let terminal = ShellTerminalView(frame: .zero)
        defer { terminal.stop() }
        let recorder = Phase7TerminalInputRecorder()
        terminal.terminalDelegate = recorder
        let panel = try openPanel(on: terminal)
        try action("control-c", in: panel).sendActions(for: .touchUpInside)
        XCTAssertEqual(recorder.sentBytes, [[3]])
        XCTAssertTrue(panel.isHidden)
        XCTAssertEqual(terminal.shortcutBar?.activePopup, MudiShortcutPopup.none)
    }

    func testSlashCommandRequiresConfirmationThenSendsTextAndEnter() async throws {
        let fixture = try Phase16TerminalFixture()
        defer { fixture.close() }
        let terminal = try await fixture.terminal()
        let panel = try openPanel(on: terminal)
        var expected: [[UInt8]] = []
        for command in ["reload", "compact", "resume", "tree"] {
            if panel.isHidden { _ = try openPanel(on: terminal) }
            try action(command, in: panel).sendActions(for: .touchUpInside)
            let confirmation = try XCTUnwrap(phase7View(with: "terminal-agent-command-confirmation", in: panel))
            XCTAssertFalse(confirmation.isHidden)
            let text = try XCTUnwrap(phase7View(with: "terminal-agent-command-text", in: panel) as? UILabel)
            XCTAssertEqual(text.text, "/" + command)
            await settle()
            let before = await fixture.channel.sent()
            XCTAssertEqual(before, expected, "Choosing a command alone must not send")
            let cancel = try button("terminal-agent-command-cancel", in: panel)
            cancel.sendActions(for: .touchUpInside)
            XCTAssertTrue(confirmation.isHidden)
            let cancelled = await fixture.channel.sent()
            XCTAssertEqual(cancelled, expected)

            try action(command, in: panel).sendActions(for: .touchUpInside)
            let confirm = try button("terminal-agent-command-confirm", in: panel)
            confirm.sendActions(for: .touchUpInside)
            // Even a stale/double confirmation must not send twice.
            confirm.sendActions(for: .touchUpInside)
            expected.append(Array(("/" + command).utf8))
            expected.append([13])
            try await fixture.waitForInputCount(expected.count)
            let sent = await fixture.channel.sent()
            XCTAssertEqual(sent, expected, "Do not clear the remote editor or inject extra bytes")
            XCTAssertTrue(confirmation.isHidden)
            XCTAssertTrue(panel.isHidden, "Successful sends dismiss the popup")
        }
    }

    func testPaneSwitchOrTypeRefreshUpdatesPresetWithoutStaleType() async throws {
        let fixture = try Phase16TerminalFixture()
        defer { fixture.close() }
        let terminal = try await fixture.terminal()
        let panel = try openPanel(on: terminal)
        try action("reload", in: panel).sendActions(for: .touchUpInside)
        let staleConfirm = try button("terminal-agent-command-confirm", in: panel)

        var unknown = fixture.pane
        unknown.agent = nil
        fixture.setPane(unknown)
        let generic = await fixture.harness.waitUntil {
            self.presetLabel(in: panel)?.text == "当前预设：通用"
        }
        XCTAssertTrue(generic)
        staleConfirm.sendActions(for: .touchUpInside)
        await settle()
        var sent = await fixture.channel.sent()
        XCTAssertEqual(sent, [], "An old agent command must not survive a type refresh")

        fixture.setPane(fixture.pane)
        let pi = await fixture.harness.waitUntil {
            self.presetLabel(in: panel)?.text == "当前预设：Pi"
        }
        XCTAssertTrue(pi)
        try action("reload", in: panel).sendActions(for: .touchUpInside)
        // Pane IDs are not globally unique across Hosts or Herdr sessions.
        fixture.model.activeConnection = ActiveSSHConnection(host: phase4Host(), session: fixture.session)
        await settle()
        staleConfirm.sendActions(for: .touchUpInside)
        await settle()
        sent = await fixture.channel.sent()
        XCTAssertEqual(sent, [], "A confirmation belongs to the original Host/pane")

        try action("reload", in: panel).sendActions(for: .touchUpInside)
        var otherSession = fixture.herdrSession
        otherSession = HerdrSession(id: "other-session", name: "other-session", workspaces: otherSession.workspaces)
        fixture.model.herdrState = .attached(session: otherSession, pane: fixture.pane)
        await settle()
        staleConfirm.sendActions(for: .touchUpInside)
        sent = await fixture.channel.sent()
        XCTAssertEqual(sent, [], "A confirmation must not cross Herdr sessions")

        try action("reload", in: panel).sendActions(for: .touchUpInside)
        terminal.updateInputFocus(isAllowed: false)
        staleConfirm.sendActions(for: .touchUpInside)
        terminal.updateInputFocus(isAllowed: true)
        staleConfirm.sendActions(for: .touchUpInside)
        await settle()
        sent = await fixture.channel.sent()
        XCTAssertEqual(sent, [], "Suspending input cancels the pending command, not just its button")

        _ = try openPanel(on: terminal)
        try action("reload", in: panel).sendActions(for: .touchUpInside)
        terminal.stop()
        staleConfirm.sendActions(for: .touchUpInside)
        await settle()
        sent = await fixture.channel.sent()
        XCTAssertEqual(sent, [], "Teardown must invalidate the pending command")
    }

    func testGenericShortcutBarLayoutAndSemanticsUnchanged() throws {
        let terminal = ShellTerminalView(frame: .zero)
        defer { terminal.stop() }
        let recorder = Phase7TerminalInputRecorder()
        terminal.terminalDelegate = recorder
        let bar = try XCTUnwrap(terminal.shortcutBar)
        bar.frame = CGRect(x: 0, y: 0, width: 320, height: 48)
        bar.layoutIfNeeded()
        let row = bar.stackView.arrangedSubviews.compactMap(\.accessibilityIdentifier)
            .filter { $0.hasPrefix("terminal-shortcut-") }
        XCTAssertEqual(row, ["escape", "tab", "control", "dpad", "compose", "paste", "history", "agent-actions"]
            .map { "terminal-shortcut-" + $0 })
        XCTAssertEqual(bar.pinnedStackView.arrangedSubviews.compactMap(\.accessibilityIdentifier),
                       ["terminal-shortcut-jump-to", "terminal-shortcut-dismiss-keyboard"])
        for key in phase7ShortcutButtons(in: bar) {
            XCTAssertGreaterThanOrEqual(key.bounds.width, 44)
            XCTAssertEqual(key.bounds.height, 44, accuracy: 0.1)
        }
        let panel = try openPanel(on: terminal)
        try action("shift-tab", in: panel).sendActions(for: .touchUpInside)
        _ = try openPanel(on: terminal)
        try action("tab", in: panel).sendActions(for: .touchUpInside)
        _ = try openPanel(on: terminal)
        try action("escape", in: panel).sendActions(for: .touchUpInside)
        XCTAssertEqual(recorder.sentBytes, [[0x1b, 0x5b, 0x5a], [0x09], [0x1b]])
        bar.toggleControl()
        XCTAssertTrue(panel.isHidden, "Agent Actions shares the existing one-popup-at-a-time policy")
        XCTAssertFalse(bar.comboPopup.isHidden)
        bar.toggleDPad()
        XCTAssertTrue(bar.comboPopup.isHidden)
        XCTAssertFalse(bar.dpadOverlay.isHidden)
    }

    private func openPanel(on terminal: ShellTerminalView) throws -> UIView {
        let bar = try XCTUnwrap(terminal.shortcutBar)
        try button("terminal-shortcut-agent-actions", in: bar).sendActions(for: .touchUpInside)
        let panel = try XCTUnwrap(phase7View(with: "terminal-agent-actions-panel", in: bar))
        XCTAssertFalse(panel.isHidden)
        return panel
    }

    private func action(_ id: String, in panel: UIView) throws -> UIButton {
        try button("terminal-agent-action-" + id, in: panel)
    }

    private func button(_ id: String, in view: UIView) throws -> UIButton {
        try XCTUnwrap(phase7View(with: id, in: view) as? UIButton, id)
    }

    private func presetLabel(in panel: UIView) -> UILabel? {
        phase7View(with: "terminal-agent-preset-label", in: panel) as? UILabel
    }

    private func presetPicker(in panel: UIView) throws -> UISegmentedControl {
        try XCTUnwrap(phase7View(with: "terminal-agent-preset-picker", in: panel) as? UISegmentedControl)
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(60))
    }
}

@MainActor
private final class Phase16TerminalFixture {
    let channel = Phase16InputChannel()
    let session: SSHShellSession
    let model: RootViewModel
    let harness: Phase7RootViewHarness
    let pane: Pane
    let herdrSession: HerdrSession

    init() throws {
        // Existing captured real Herdr CLI fixture, not a made-up wire shape.
        herdrSession = try XCTUnwrap(Phase3HerdrFixtures.single().sessions.first)
        pane = try XCTUnwrap(herdrSession.workspaces.flatMap(\.tabs).flatMap(\.panes)
            .first { $0.agent?.name == "pi" })
        session = SSHShellSession(connectedChannel: channel)
        model = RootViewModel(preferencesStore: Phase7PreferencesStore())
        model.activeConnection = ActiveSSHConnection(host: phase4Host(), session: session)
        model.herdrState = .attached(session: herdrSession, pane: pane)
        model.isLocalNetworkOnboardingRequired = false
        harness = Phase7RootViewHarness(rootView: RootView(model: model))
    }

    func setPane(_ pane: Pane) {
        model.herdrState = .attached(session: herdrSession, pane: pane)
    }

    func terminal(excluding previous: ShellTerminalView? = nil) async throws -> ShellTerminalView {
        let appeared = await harness.waitUntil {
            phase7Descendants(of: self.harness.controller.view)
                .compactMap { $0 as? ShellTerminalView }.contains { $0 !== previous }
        }
        XCTAssertTrue(appeared)
        return try XCTUnwrap(phase7Descendants(of: harness.controller.view)
            .compactMap { $0 as? ShellTerminalView }.first { $0 !== previous })
    }

    func waitForInputCount(_ count: Int) async throws {
        for _ in 0..<200 {
            if await channel.sent().count >= count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        let sent = await channel.sent()
        XCTFail("Expected \(count) PTY inputs; received \(sent)")
    }

    func close() {
        harness.close()
        Task { await channel.close() }
    }
}

private actor Phase16InputChannel: PTYOutputChannel {
    private let output = AsyncThrowingStream<[UInt8], Error>.makeStream()
    private var bytes: [[UInt8]] = []
    func outputStream() -> AsyncThrowingStream<[UInt8], Error> { output.stream }
    func send(_ bytes: [UInt8]) { self.bytes.append(bytes) }
    func resize(columns: Int, rows: Int) {}
    func close() { output.continuation.finish() }
    func sent() -> [[UInt8]] { bytes }
}
