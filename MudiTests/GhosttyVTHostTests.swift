import GhosttyVt
import HerdrKit
import UIKit
import XCTest
@testable import Mudi

@MainActor
final class GhosttyVTHostTests: XCTestCase {
    func testSwiftTermDefaultAndVTImplementTheSameShortcutHost() async throws {
        for view in [ShellTerminalView(frame: .zero), try GhosttyVTView()] as [UIView] {
            let host = try XCTUnwrap(view as? any TerminalHost, "Both engines need the real neutral host contract")
            let channel = GhosttyVTTestPTY()
            host.start(session: SSHShellSession(connectedChannel: channel), onError: { XCTFail($0) }, onClosed: {})
            defer { host.stop() }
            let bar = try XCTUnwrap(host.shortcutBar)
            bar.sendEscape()
            bar.sendTab()
            bar.toggleControl()
            host.insertText("c")
            bar.send([0x1b, 0x5b, 0x5a])
            bar.handle(.enter)
            let received = await ghosttyWait { (await channel.snapshot()).sent.count == 5 }
            XCTAssertTrue(received)
            let snapshot = await channel.snapshot()
            XCTAssertEqual(snapshot.sent, [[27], [9], [3], [27, 91, 90], [13]])
            XCTAssertFalse(host.controlModifier)
            XCTAssertEqual(bar.activePopup, .none, "Consumed keyboard Ctrl must close the real popup")
            XCTAssertEqual(snapshot.readers, 1)
        }
    }

    func testVTSharedDPadAndComposerUseCurrentModesAndByteSemantics() async throws {
        let view = try GhosttyVTView()
        let host = try XCTUnwrap(view as? any TerminalHost)
        let channel = GhosttyVTTestPTY()
        host.start(session: SSHShellSession(connectedChannel: channel), onError: { XCTFail($0) }, onClosed: {})
        defer { host.stop() }
        _ = try view.feed(Data("\u{1b}[?1h\u{1b}[?2004h".utf8))
        let bar = try XCTUnwrap(host.shortcutBar)
        bar.handle(.cursorUp)
        bar.toggleControl()
        bar.handle(.cursorRight)
        bar.sendComposedText("中\n文", bracketedPaste: true, appendReturn: true)
        bar.sendComposedText("raw\ntext", bracketedPaste: false, appendReturn: false)
        let received = await ghosttyWait { (await channel.snapshot()).sent.count == 5 }
        XCTAssertTrue(received)
        let snapshot = await channel.snapshot()
        XCTAssertEqual(snapshot.sent.map { Data($0) }, [Data("\u{1b}OA".utf8), Data("\u{1b}[1;5C".utf8),
            Data("\u{1b}[200~中\n文\u{1b}[201~".utf8), Data([13]), Data("raw\ntext".utf8)])
        XCTAssertNil(view.inputAccessoryView)
    }

    func testVTUIKitHardwareCommandsAndCompositionDoNotCompete() async throws {
        let view = try GhosttyVTView()
        let host = try XCTUnwrap(view as? any TerminalHost)
        let channel = GhosttyVTTestPTY()
        host.start(session: SSHShellSession(connectedChannel: channel), onError: { XCTFail($0) }, onClosed: {})
        defer { host.stop() }
        let control = try XCTUnwrap(view.keyCommands?.first { $0.input == "c" && $0.modifierFlags == .control })
        _ = view.perform(control.action, with: control)
        _ = try view.feed(Data("\u{1b}[?1h".utf8))
        let arrow = try XCTUnwrap(view.keyCommands?.first { $0.input == UIKeyCommand.inputUpArrow && $0.modifierFlags.isEmpty })
        _ = view.perform(arrow.action, with: arrow)
        view.setMarkedText("ni", selectedRange: .init(location: 2, length: 0))
        _ = view.perform(arrow.action, with: arrow)
        XCTAssertEqual(host.shortcutBar?.compositionLabel.text, "ni")
        XCTAssertTrue(host.shortcutBar?.isShowingComposition == true)
        view.setMarkedText(nil, selectedRange: .init(location: 0, length: 0))
        let received = await ghosttyWait { (await channel.snapshot()).sent.count == 2 }
        XCTAssertTrue(received)
        let snapshot = await channel.snapshot()
        XCTAssertEqual(snapshot.sent, [[3], [27, 79, 65]])
        XCTAssertFalse(host.shortcutBar?.isShowingComposition == true)
    }

    func testSessionReplacementPreservesVTStateAndFocusWithoutOldInput() async throws {
        let view = try GhosttyVTView(configuration: .init(columns: 30, rows: 4))
        let host = try XCTUnwrap(view as? any TerminalHost)
        let first = GhosttyVTTestPTY()
        let second = GhosttyVTTestPTY()
        let firstSession = SSHShellSession(connectedChannel: first)
        let secondSession = SSHShellSession(connectedChannel: second)
        let window = Phase7TerminalScreenHarness.makeWindow()
        let controller = UIViewController()
        window.rootViewController = controller
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        controller.view.addSubview(view)
        window.makeKeyAndVisible()
        defer { host.stop(); window.isHidden = true; window.rootViewController = nil }
        host.start(session: firstSession, onError: { XCTFail($0) }, onClosed: {})
        let attached = await ghosttyWait { (await first.snapshot()).readers == 1 }
        XCTAssertTrue(attached)
        await first.emit("keep\r\nstate\u{1b}[?1h")
        let rendered = await ghosttyWait { view.screen.text(at: 0).hasPrefix("keep") }
        XCTAssertTrue(rendered)
        let engine = ObjectIdentifier(view.terminal)
        XCTAssertTrue(host.becomeFirstResponder())
        view.setMarkedText("not committed", selectedRange: .init(location: 13, length: 0))
        host.updateSession(session: secondSession, onError: { XCTFail($0) }, onClosed: {})
        XCTAssertTrue(view.isFirstResponder)
        XCTAssertNil(view.markedTextRange)
        XCTAssertEqual(ObjectIdentifier(view.terminal), engine)
        XCTAssertTrue(view.screen.text(at: 0).hasPrefix("keep"))
        host.insertText("new")
        host.updateSession(session: secondSession, onError: { XCTFail($0) }, onClosed: {})
        let sent = await ghosttyWait { (await second.snapshot()).sent == [Array("new".utf8)] }
        XCTAssertTrue(sent)
        let old = await first.snapshot()
        let new = await second.snapshot()
        XCTAssertTrue(old.sent.isEmpty)
        XCTAssertEqual(old.closes, 0, "A renderer must not change the owner's replacement/disconnect policy")
        XCTAssertEqual(new.readers, 1)
        XCTAssertEqual(new.closes, 0)
    }

    func testHiddenOffWindowAndBackgroundKeepOutputAndDoNotStealFocus() async throws {
        let view = try GhosttyVTView(configuration: .init(columns: 20, rows: 3))
        let host = try XCTUnwrap(view as? any TerminalHost)
        let channel = GhosttyVTTestPTY()
        host.start(session: SSHShellSession(connectedChannel: channel), onError: { XCTFail($0) }, onClosed: {})
        defer { host.stop() }
        let window = Phase7TerminalScreenHarness.makeWindow()
        let controller = UIViewController()
        window.rootViewController = controller
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 180)
        controller.view.addSubview(view)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        view.isHidden = true
        view.removeFromSuperview()
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        await channel.emit("one\r\ntwo\r\nthree\r\nfour\r\nfive\r\nsix\r\nkeep hidden")
        let received = await ghosttyWait { view.screen.rows.indices.contains { view.screen.text(at: $0).contains("keep hidden") } }
        XCTAssertTrue(received)
        let before = view.screen.rows
        let scrollback = try view.terminal.status().scrollbackRows
        controller.view.addSubview(view)
        view.isHidden = false
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        view.layoutIfNeeded()
        XCTAssertFalse(view.isFirstResponder)
        XCTAssertEqual(view.screen.rows, before)
        XCTAssertEqual(try view.terminal.status().scrollbackRows, scrollback)
        let snapshot = await channel.snapshot()
        XCTAssertEqual(snapshot.readers, 1)
        XCTAssertEqual(snapshot.closes, 0)
        host.updateInputFocus(isAllowed: false)
        host.insertText("forbidden")
        try await Task.sleep(for: .milliseconds(20))
        let finalSnapshot = await channel.snapshot()
        XCTAssertTrue(finalSnapshot.sent.isEmpty)
    }
}
