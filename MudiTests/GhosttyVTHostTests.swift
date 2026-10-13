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
        ghosttyPress(view, GhosttyVTTestKey(.keyboardC, .control, ignoring: "c"))
        _ = try view.feed(Data("\u{1b}[?1h".utf8))
        ghosttyPress(view, GhosttyVTTestKey(.keyboardUpArrow))
        view.setMarkedText("ni", selectedRange: .init(location: 2, length: 0))
        ghosttyPress(view, GhosttyVTTestKey(.keyboardUpArrow))
        XCTAssertEqual(host.shortcutBar?.compositionLabel.text, "ni")
        XCTAssertTrue(host.shortcutBar?.isShowingComposition == true)
        view.setMarkedText(nil, selectedRange: .init(location: 0, length: 0))
        let received = await ghosttyWait { (await channel.snapshot()).sent.count == 2 }
        XCTAssertTrue(received)
        let snapshot = await channel.snapshot()
        XCTAssertEqual(snapshot.sent, [[3], [27, 79, 65]])
        XCTAssertFalse(host.shortcutBar?.isShowingComposition == true)
    }

    /// Production UIKit `pressesBegan` → SwiftTerm 1.15 (dd2fb8ac) hardware key
    /// semantics → real VT encoder → the same PTY. Handled keys never also reach
    /// UIKit text input; text/Return/Backspace stay with insertText/deleteBackward.
    func testHardwarePressesKeepSwiftTermKeyMapThroughRealVTAndSamePTY() async throws {
        let view = try GhosttyVTView(configuration: .init(columns: 20, rows: 4))
        let responder = GhosttyVTPressRecorder()
        responder.addSubview(view)
        let host = try XCTUnwrap(view as? any TerminalHost)
        let channel = GhosttyVTTestPTY()
        host.start(session: SSHShellSession(connectedChannel: channel), onError: { XCTFail($0) }, onClosed: {})
        defer { host.stop() }
        typealias K = GhosttyVTTestKey
        let mapped: [(String, K, String)] = [
            ("Home", K(.keyboardHome), "\u{1b}[H"), ("End", K(.keyboardEnd), "\u{1b}[F"),
            ("ForwardDelete", K(.keyboardDeleteForward), "\u{1b}[3~"),
            ("F1", K(.keyboardF1), "\u{1b}OP"), ("F4", K(.keyboardF4), "\u{1b}OS"), ("F5", K(.keyboardF5), "\u{1b}[15~"),
            ("F11", K(.keyboardF11), "\u{1b}[23~"),
            ("Option+B", K(.keyboardB, .alternate, ignoring: "b", typed: "∫"), "\u{1b}b"),
            ("Option+F", K(.keyboardF, .alternate, ignoring: "f", typed: "ƒ"), "\u{1b}f"),
            ("Option+Left", K(.keyboardLeftArrow, .alternate), "\u{1b}b"),
            ("Option+Right", K(.keyboardRightArrow, .alternate), "\u{1b}f"),
            ("Ctrl+Left", K(.keyboardLeftArrow, .control), "\u{1b}[1;5D"),
            ("Ctrl+C", K(.keyboardC, .control, ignoring: "c"), "\u{03}"),
            ("Ctrl+Shift+C", K(.keyboardC, [.control, .shift], ignoring: "c"), "\u{03}"),
            ("Ctrl+I", K(.keyboardI, .control, ignoring: "i"), "\t"),
            ("Ctrl+M", K(.keyboardM, .control, ignoring: "m"), "\r"),
            ("Ctrl+[", K(.keyboardOpenBracket, .control, ignoring: "["), "\u{1b}"),
            ("Ctrl+\\", K(.keyboardBackslash, .control, ignoring: "\\"), "\u{1c}"),
            ("Ctrl+Space", K(.keyboardSpacebar, .control, ignoring: " "), "\u{00}"),
            ("Shift+Tab", K(.keyboardTab, .shift), "\u{1b}[Z"), ("Tab", K(.keyboardTab), "\t"),
            ("Escape", K(.keyboardEscape), "\u{1b}"), ("Up", K(.keyboardUpArrow), "\u{1b}[A"),
        ]
        for (_, key, _) in mapped { ghosttyPress(view, key) }
        let sent = await ghosttyWait { (await channel.snapshot()).sent.count == mapped.count }
        XCTAssertTrue(sent)
        var snapshot = await channel.snapshot()
        for (index, item) in mapped.enumerated() {
            XCTAssertEqual(snapshot.sent.indices.contains(index) ? snapshot.sent[index] : [], Array(item.2.utf8), item.0)
        }
        XCTAssertEqual(responder.forwarded, [], "Handled hardware keys must not also be inserted by UIKit text input")

        _ = try view.feed(Data("\u{1b}[?1h".utf8))
        ghosttyPress(view, K(.keyboardHome))
        ghosttyPress(view, K(.keyboardEnd))
        let application = await ghosttyWait { (await channel.snapshot()).sent.count == mapped.count + 2 }
        XCTAssertTrue(application)
        snapshot = await channel.snapshot()
        XCTAssertEqual(Array(snapshot.sent.suffix(2)), [Array("\u{1b}OH".utf8), Array("\u{1b}OF".utf8)],
                       "VT application cursor mode owns Home/End encoding")
        // Kitty keyboard mode (SwiftTerm switches to its kitty encoder): the
        // real VT encoder owns disambiguated Escape / Ctrl+letter, not legacy bytes.
        _ = try view.feed(Data("\u{1b}[>1u".utf8))
        ghosttyPress(view, K(.keyboardEscape))
        ghosttyPress(view, K(.keyboardC, .control, ignoring: "c"))
        let kitty = await ghosttyWait { (await channel.snapshot()).sent.count == mapped.count + 4 }
        XCTAssertTrue(kitty)
        snapshot = await channel.snapshot()
        XCTAssertEqual(Array(snapshot.sent.suffix(2)), [Array("\u{1b}[27u".utf8), Array("\u{1b}[99;5u".utf8)])
        _ = try view.feed(Data("\u{1b}[<u".utf8))

        ghosttyPress(view, K(.keyboardA, ignoring: "a"))
        ghosttyPress(view, K(.keyboardReturnOrEnter, ignoring: "\r"))
        ghosttyPress(view, K(.keyboardDeleteOrBackspace, ignoring: "\u{8}"))
        view.setMarkedText("ni", selectedRange: .init(location: 2, length: 0))
        ghosttyPress(view, K(.keyboardHome))
        ghosttyPress(view, K(.keyboardC, .control, ignoring: "c"))
        ghosttyPress(view, K(.keyboardB, .alternate, ignoring: "b"))
        XCTAssertEqual(responder.forwarded, [.keyboardA, .keyboardReturnOrEnter, .keyboardDeleteOrBackspace,
                                             .keyboardHome, .keyboardC, .keyboardB],
                       "Plain text/Return/Backspace and every key during marked text belong to UIKit text input/IME")
        XCTAssertEqual(view.markedTextRange.flatMap { view.text(in: $0) }, "ni")
        try await Task.sleep(for: .milliseconds(30))
        let final = await channel.snapshot()
        XCTAssertEqual(final.sent.count, mapped.count + 4, "pressesBegan must not send text that insertText will commit")
        XCTAssertEqual(final.readers, 1)
    }

    func testHeldHardwareKeyRepeatsLikeSwiftTermAndStopsOnRelease() async throws {
        let view = try GhosttyVTView(configuration: .init(columns: 20, rows: 4))
        let host = try XCTUnwrap(view as? any TerminalHost)
        let channel = GhosttyVTTestPTY()
        host.start(session: SSHShellSession(connectedChannel: channel), onError: { XCTFail($0) }, onClosed: {})
        defer { host.stop() }
        let press = GhosttyVTTestPress(GhosttyVTTestKey(.keyboardLeftArrow))
        view.pressesBegan([press], with: nil)
        let repeated = await ghosttyWait { (await channel.snapshot()).sent.count >= 3 }
        XCTAssertTrue(repeated, "A held hardware key repeats (UIKit delivers pressesBegan once)")
        view.pressesEnded([press], with: nil)
        let count = await channel.snapshot().sent.count
        try await Task.sleep(for: .milliseconds(300))
        let snapshot = await channel.snapshot()
        XCTAssertEqual(snapshot.sent.count, count, "Release stops repeating")
        XCTAssertTrue(snapshot.sent.allSatisfy { $0 == Array("\u{1b}[D".utf8) })
    }

    /// A key held on the old session must not keep repeating into the
    /// replacement session's PTY; the new session's own presses still repeat.
    func testHeldHardwareKeyRepeatDoesNotCrossSessionReplacement() async throws {
        let view = try GhosttyVTView(configuration: .init(columns: 20, rows: 4))
        let host = try XCTUnwrap(view as? any TerminalHost)
        let first = GhosttyVTTestPTY()
        let second = GhosttyVTTestPTY()
        let firstSession = SSHShellSession(connectedChannel: first)
        host.start(session: firstSession, onError: { XCTFail($0) }, onClosed: {})
        defer { host.stop() }
        await first.emit("keep")
        let rendered = await ghosttyWait { view.screen.text(at: 0).hasPrefix("keep") }
        XCTAssertTrue(rendered)
        let engine = ObjectIdentifier(view.terminal)
        let held = GhosttyVTTestPress(GhosttyVTTestKey(.keyboardC, .control, ignoring: "c"))
        view.pressesBegan([held], with: nil)
        let sentOld = await ghosttyWait { (await first.snapshot()).sent == [[3]] }
        XCTAssertTrue(sentOld)
        host.updateSession(session: SSHShellSession(connectedChannel: second), onError: { XCTFail($0) }, onClosed: {})
        // Past the 0.4 s initial delay and several 0.1 s repeat periods.
        try await Task.sleep(for: .milliseconds(750))
        let oldAfter = await first.snapshot()
        let newAfter = await second.snapshot()
        XCTAssertEqual(oldAfter.sent, [[3]], "Old session only has the byte sent before replacement")
        XCTAssertTrue(newAfter.sent.isEmpty, "A key held on the old session must not repeat into the new PTY")
        view.pressesEnded([held], with: nil)
        XCTAssertEqual(ObjectIdentifier(view.terminal), engine)
        XCTAssertTrue(view.screen.text(at: 0).hasPrefix("keep"), "Replacement keeps VT state")

        // The replacement session's own held key sends and repeats, then stops.
        let press = GhosttyVTTestPress(GhosttyVTTestKey(.keyboardDeleteForward))
        view.pressesBegan([press], with: nil)
        let repeated = await ghosttyWait { (await second.snapshot()).sent.count >= 3 }
        XCTAssertTrue(repeated)
        view.pressesEnded([press], with: nil)
        let count = await second.snapshot().sent.count
        try await Task.sleep(for: .milliseconds(300))
        let final = await second.snapshot()
        XCTAssertEqual(final.sent.count, count)
        XCTAssertTrue(final.sent.allSatisfy { $0 == Array("\u{1b}[3~".utf8) })
        let oldFinal = await first.snapshot()
        XCTAssertEqual(oldFinal.sent, [[3]])
        XCTAssertEqual(oldFinal.closes, 0)

        // Same-session update is a no-op boundary: a held key keeps repeating.
        let same = GhosttyVTTestPress(GhosttyVTTestKey(.keyboardLeftArrow))
        let before = await second.snapshot().sent.count
        view.pressesBegan([same], with: nil)
        host.updateSession(session: try XCTUnwrap(view.session), onError: { XCTFail($0) }, onClosed: {})
        let kept = await ghosttyWait { (await second.snapshot()).sent.count >= before + 3 }
        XCTAssertTrue(kept, "Same-session update must not cancel an active repeat")
        view.pressesEnded([same], with: nil)
    }

    func testHardwarePageKeysKeepLocalHerdrAndWheelScrollOwnership() async throws {
        // Normal session: local VT history unless the app enabled application cursor.
        let channel = GhosttyVTTestPTY()
        let view = try GhosttyVTView(configuration: .init(columns: 20, rows: 3))
        let host = try XCTUnwrap(view as? any TerminalHost)
        host.start(session: SSHShellSession(connectedChannel: channel), onError: { XCTFail($0) }, onClosed: {})
        defer { host.stop() }
        let resolved = await ghosttyWait { view.isScrollOwnerResolved }
        XCTAssertTrue(resolved)
        _ = try view.feed(Data(((1...20).map { "line \($0)" }.joined(separator: "\r\n")).utf8))
        ghosttyPress(view, GhosttyVTTestKey(.keyboardPageUp))
        XCTAssertFalse(try view.terminal.status().isViewportActive)
        ghosttyPress(view, GhosttyVTTestKey(.keyboardPageDown))
        XCTAssertTrue(try view.terminal.status().isViewportActive)
        _ = try view.feed(Data("\u{1b}[?1h".utf8))
        ghosttyPress(view, GhosttyVTTestKey(.keyboardPageUp))
        ghosttyPress(view, GhosttyVTTestKey(.keyboardPageDown))
        let app = await ghosttyWait { (await channel.snapshot()).sent.count == 2 }
        XCTAssertTrue(app)
        let local = await channel.snapshot()
        XCTAssertEqual(local.sent, [Array("\u{1b}[5~".utf8), Array("\u{1b}[6~".utf8)])

        // Herdr: the existing PTYScrollChannel owns PageUp/Down by visible rows.
        let herdr = GhosttyVTTestScrollPTY()
        let herdrView = try GhosttyVTView(configuration: .init(columns: 20, rows: 3))
        let herdrHost = try XCTUnwrap(herdrView as? any TerminalHost)
        herdrHost.start(session: SSHShellSession(connectedChannel: herdr), onError: { XCTFail($0) }, onClosed: {})
        defer { herdrHost.stop() }
        let herdrReady = await ghosttyWait { herdrView.scrollCapability == .hostScrollback }
        XCTAssertTrue(herdrReady)
        _ = try herdrView.feed(Data("\u{1b}[?1h".utf8))
        ghosttyPress(herdrView, GhosttyVTTestKey(.keyboardPageUp))
        ghosttyPress(herdrView, GhosttyVTTestKey(.keyboardPageDown))
        let scrolled = await ghosttyWait { await herdr.requests().count == 2 }
        XCTAssertTrue(scrolled)
        let requests = await herdr.requests()
        XCTAssertEqual(requests.map(\.direction), [.up, .down])
        XCTAssertEqual(requests.map(\.lines), [3, 3])
        let herdrSent = await herdr.recording.snapshot()
        XCTAssertTrue(herdrSent.sent.isEmpty)

        // Mosh wheel: VT mouse-mode encoded wheel only while reporting is on.
        let wheel = GhosttyVTTestWheelPTY()
        let wheelView = try GhosttyVTView(configuration: .init(columns: 20, rows: 3))
        let wheelHost = try XCTUnwrap(wheelView as? any TerminalHost)
        wheelHost.start(session: SSHShellSession(connectedChannel: wheel), onError: { XCTFail($0) }, onClosed: {})
        defer { wheelHost.stop() }
        let wheelReady = await ghosttyWait { wheelView.scrollCapability == .remoteMouseWheel }
        XCTAssertTrue(wheelReady)
        wheelView.frame.size = CGSize(width: wheelView.cellSize.width * 20, height: wheelView.cellSize.height * 3)
        ghosttyPress(wheelView, GhosttyVTTestKey(.keyboardPageUp))
        try await Task.sleep(for: .milliseconds(30))
        let off = await wheel.recording.snapshot()
        XCTAssertTrue(off.sent.isEmpty, "Wheel owner with mouse reporting off sends nothing")
        _ = try wheelView.feed(Data("\u{1b}[?1000h\u{1b}[?1006h".utf8))
        ghosttyPress(wheelView, GhosttyVTTestKey(.keyboardPageDown))
        let wheeled = await ghosttyWait { (await wheel.recording.snapshot()).sent.count == 3 }
        XCTAssertTrue(wheeled)
        let events = await wheel.recording.snapshot()
        XCTAssertTrue(events.sent.allSatisfy { String(decoding: $0, as: UTF8.self).hasPrefix("\u{1b}[<65;") })
        XCTAssertTrue(try wheelView.terminal.status().isViewportActive)
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
        view.layoutIfNeeded() // Establish the viewport BEFORE measuring retained state.
        view.isHidden = true
        view.removeFromSuperview()
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        await channel.emit((1...20).map { "line \($0)" }.joined(separator: "\r\n") + "\r\nkeep hidden")
        let received = await ghosttyWait { view.screen.rows.indices.contains { view.screen.text(at: $0).contains("keep hidden") } }
        XCTAssertTrue(received)
        let before = view.screen.rows
        let scrollback = try view.terminal.status().scrollbackRows
        XCTAssertGreaterThan(scrollback, 0)
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
