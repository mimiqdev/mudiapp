import HerdrKit
import SwiftUI
import UIKit
import XCTest
@testable import Mudi

@MainActor
final class UIPolishRenderTests: XCTestCase {
    func testHostLargeTitleRemainsVisibleInBothAppearances() async throws {
        let host = Host(displayName: "devbox", hostname: "devbox.local", username: "tony")
        for style in [UIUserInterfaceStyle.dark, .light] {
            let harness = UIPolishHarness(NavigationStack {
                HostListView(hosts: [host], connectionState: .idle, errorMessage: nil,
                             onConnect: { _ in }, onReconnect: {}, onAdd: {}, onEdit: { _ in }, onDelete: { _ in })
            }, style: style)
            defer { harness.close() }
            await harness.settle()
            let label = try XCTUnwrap(phase7Descendants(of: harness.window).compactMap { $0 as? UILabel }
                .first { $0.text == "主机" && $0.font.pointSize > 20 })
            let image = harness.screenshot()
            let frame = label.convert(label.bounds, to: harness.controller.view)
            let rect = CGRect(x: frame.minX * image.scale, y: frame.minY * image.scale,
                              width: frame.width * image.scale, height: frame.height * image.scale)
            let crop = try XCTUnwrap(image.cgImage?.cropping(to: rect))
            var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
            let context = try XCTUnwrap(CGContext(data: &pixels, width: crop.width, height: crop.height,
                bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
            let visibleInk = stride(from: 0, to: pixels.count, by: 4).filter {
                style == .dark ? pixels[$0] > 160 : pixels[$0] < 100
            }.count
            XCTAssertGreaterThan(visibleInk, 50, "Large title must be visible above the saved-host section")
        }
    }

    func testFigmaAssetsRetainOriginalSizes() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "FigmaAssets", withExtension: "json"))
        let assets = try JSONDecoder().decode([[String: String]].self, from: Data(contentsOf: url))
        XCTAssertEqual(assets.count, MudiIcon.allCases.count)
        for asset in assets {
            let name = try XCTUnwrap(asset["name"])
            let image = try XCTUnwrap(UIImage(named: "Mudi" + name), name)
            // actool rounds fractional vector canvases up to the next display pixel.
            let width = try XCTUnwrap(Double(asset["width"] ?? ""))
            let height = try XCTUnwrap(Double(asset["height"] ?? ""))
            XCTAssertEqual(image.size.width, ceil(width * image.scale) / image.scale, accuracy: 0.01, name)
            XCTAssertEqual(image.size.height, ceil(height * image.scale) / image.scale, accuracy: 0.01, name)
        }
    }

    func testArcActivationPickerPersistsAndRendersInBothAppearances() async throws {
        for style in [UIUserInterfaceStyle.dark, .light] {
            let name = "ThumbArcSettings.\(UUID())"
            defer { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
            let defaults = UserDefaults(suiteName: name)!
            let store = UserDefaultsPreferencesStore(defaults: defaults)
            let model = RootViewModel(preferencesStore: store)
            let harness = UIPolishHarness(NavigationStack {
                ThumbArcSettingsView(model: model)
            }, style: style)
            defer { harness.close() }
            await harness.settle()
            let scroll = try XCTUnwrap(phase7Descendants(of: harness.controller.view)
                .compactMap { $0 as? UIScrollView }.first { $0.contentSize.height > $0.bounds.height })
            scroll.setContentOffset(CGPoint(x: 0, y: max(-scroll.adjustedContentInset.top,
                scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)), animated: false)
            await harness.settle()
            let picker = try XCTUnwrap(phase7Descendants(of: harness.controller.view)
                .compactMap { $0 as? UISegmentedControl }.first { $0.numberOfSegments == 3 })
            XCTAssertEqual((0..<3).map { picker.titleForSegment(at: $0) }, ["短", "中", "长"])
            XCTAssertEqual(picker.selectedSegmentIndex, 1)
            picker.selectedSegmentIndex = 2
            picker.sendActions(for: .valueChanged)
            await harness.settle()
            XCTAssertEqual(model.preferences.thumbArc.activationDistance, .long)
            let restored = try await store.load()
            XCTAssertEqual(restored.thumbArc.activationDistance, .long)
            attach("ArcGestures-" + (style == .dark ? "dark" : "light"), image: harness.screenshot())
        }
    }

    func testRenderDesignedSurfacesInBothAppearances() async throws {
        let host = Host(displayName: "devbox", addresses: [
            HostAddress(address: "devbox.local", label: "LAN"),
            HostAddress(address: "100.64.0.12", label: "Tail"),
            HostAddress(address: "dev.example.com", label: "公网")
        ], username: "tony", preferredTransport: .mosh)
        let idle = Host(displayName: "cloud", hostname: "cloud.example.com", username: "tony")
        let snapshot = HerdrSnapshot(sessions: [HerdrSession(id: "default", name: "Default", isDefault: true, workspaces: [
            Workspace(id: "mudi", name: "mudi", tabs: [Tab(id: "coding", name: "coding", panes: [
                Pane(id: "pi", title: "UI polish", agent: Agent(name: "Pi", state: .working)),
                Pane(id: "review", title: "Review", agent: Agent(name: "Claude", state: .waitingForInput)),
                Pane(id: "tests", title: "Tests", agent: Agent(name: "Codex", state: .done)),
                Pane(id: "shell", title: "Shell")
            ])])
        ])])
        for style in [UIUserInterfaceStyle.dark, .light] {
            let suffix = style == .dark ? "dark" : "light"
            await capture("Hosts-" + suffix, view: NavigationStack {
                HostListView(hosts: [host, idle], connectionState: .connected, stateOwnerHostID: host.id,
                             errorMessage: nil, onConnect: { _ in }, onReconnect: {}, onAdd: {}, onEdit: { _ in }, onDelete: { _ in })
            }, style: style)
            await capture("HostEdit-" + suffix, view: NavigationStack {
                SSHConnectionForm(host: host, credentials: nil, onSave: { _, _ in }, onCancel: {})
            }, style: style)
            await capture("PanePicker-" + suffix, view: PanePickerView(
                state: PanePickerState(host: host, origin: .terminal, snapshot: snapshot),
                onDismiss: {}, onRefresh: {}, onCreateWorkspace: {}, isCreatingWorkspace: false,
                onSelectPane: { _ in }, onSelectOrdinaryTerminal: {}, onAppear: {}
            ), style: style)
            if style == .dark {
                let longHost = Host(displayName: "研发与发布环境 · 长名称主机",
                    hostname: "production-build-host.internal.example.com", username: "developer")
                await capture("Hosts-LargeType", view: NavigationStack {
                    HostListView(hosts: [longHost], connectionState: .idle, errorMessage: nil,
                        onConnect: { _ in }, onReconnect: {}, onAdd: {}, onEdit: { _ in }, onDelete: { _ in })
                }.environment(\.dynamicTypeSize, .accessibility3), style: style)
            }
            await capture("ArcSettings-" + suffix, view: NavigationStack {
                ThumbArcSettingsView(model: RootViewModel())
            }, style: style)
            let session = SSHShellSession(connectedChannel: RenderChannel())
            let harness = UIPolishHarness(NavigationStack {
                TerminalScreen(host: host, session: session, title: "Pi · UI polish", transport: .mosh,
                               onDisconnect: {}, onOpenPanePicker: {}, onBackToHosts: {})
            }, style: style)
            await harness.settle()
            let terminal = try XCTUnwrap(phase7Descendants(of: harness.controller.view).compactMap { $0 as? ShellTerminalView }.first)
            terminal.feed(text: "\u{1b}[32mtony@devbox\u{1b}[0m ~/mudi\r\n$ swift test\r\n\r\n\u{1b}[32m✓ All tests passed\u{1b}[0m\r\n\r\n$ ")
            await harness.settle()
            attach("Terminal-" + suffix, image: harness.screenshot())
            terminal.shortcutBar?.toggleDPad()
            await harness.settle()
            attach("DPad-" + suffix, image: harness.screenshot())
            terminal.shortcutBar?.activePopup = .none
            terminal.shortcutBar?.applyPopupState()
            let overlay = terminal.thumbArcOverlay
            overlay.frame = terminal.bounds
            terminal.addSubview(overlay)
            let origin = CGPoint(x: terminal.bounds.width * 0.75, y: terminal.bounds.height * 0.62)
            overlay.begin(origin: origin, preferences: ThumbArcPreferences())
            let layout = ThumbArcLayout(origin: origin, bounds: overlay.bounds, count: 6, isLeftHanded: false)
            overlay.select(at: layout.centers[1])
            await harness.settle()
            attach("ThumbArc-" + suffix, image: harness.screenshot())
            overlay.cancel()
            terminal.shortcutBar?.openCompose()
            let card = try XCTUnwrap(terminal.shortcutBar?.composer)
            card.setText("帮我检查终端布局：\n1. 中文输入与候选栏\n2. 多行内容保留\n3. 发送前可继续编辑")
            await harness.settle()
            attach("Composer-" + suffix, image: harness.screenshot())
            await allowSimulatorCapture("Composer-" + suffix)
            card.setText((1...42).map { "第 \($0) 行内容" }.joined(separator: "\n"))
            card.sendButton.sendActions(for: .touchUpInside)
            await harness.settle()
            attach("ComposerConfirm-" + suffix, image: harness.screenshot())
            await allowSimulatorCapture("ComposerConfirm-" + suffix)
            terminal.shortcutBar?.closeCompose()
            harness.close()
        }
    }

    private func capture<V: View>(_ name: String, view: V, style: UIUserInterfaceStyle) async {
        let harness = UIPolishHarness(view, style: style)
        await harness.settle()
        attach(name, image: harness.screenshot())
        harness.close()
    }
    private func attach(_ name: String, image: UIImage) {
        let attachment = XCTAttachment(image: image)
        attachment.name = "UIPolish-" + name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    private func allowSimulatorCapture(_ name: String) async {
        print("MUDI_SIM_CAPTURE: " + name)
        fflush(stdout)
        try? await Task.sleep(for: .seconds(2))
    }
}

private actor RenderChannel: PTYChannel {
    func send(_ bytes: [UInt8]) async throws {}
    func resize(columns: Int, rows: Int) async throws {}
    func close() async {}
}
