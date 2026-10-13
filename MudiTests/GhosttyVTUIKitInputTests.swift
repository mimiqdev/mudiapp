import GhosttyVt
import HerdrKit
import UIKit
import XCTest
@testable import Mudi

@MainActor
final class GhosttyVTUIKitInputTests: XCTestCase {
    func testMarkedUpdatesAndCancellationDoNotSendToPTY() async throws {
        let channel = GhosttyVTTestPTY()
        let view = try GhosttyVTView()
        let adapter = GhosttyVTSessionAdapter(view: view, session: SSHShellSession(connectedChannel: channel))
        adapter.start()
        defer { adapter.stop() }
        let input = try XCTUnwrap(view as? any UITextInput,
                                  "The experimental surface must provide a real UIKit UITextInput, not just sendCommittedText")
        let delegate = TerminalCompositionInputDelegate()
        var visibleText: String?
        delegate.onTextChange = {
            visibleText = $0.markedTextRange.flatMap { $0.isEmpty ? nil : $0 }.flatMap { input.text(in: $0) }
        }
        input.inputDelegate = delegate
        input.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertEqual(visibleText, "ni")
        input.setMarkedText("你", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertEqual(visibleText, "你")
        input.setMarkedText(nil, selectedRange: NSRange(location: 0, length: 0))
        XCTAssertNil(input.markedTextRange)
        XCTAssertNil(visibleText)
        try await Task.sleep(for: .milliseconds(20))
        let snapshot = await channel.snapshot()
        XCTAssertTrue(snapshot.sent.isEmpty)
    }

    func testUIKitCommitAndUnmarkSendEachCompositionOnlyOnce() async throws {
        let channel = GhosttyVTTestPTY()
        let view = try GhosttyVTView()
        let adapter = GhosttyVTSessionAdapter(view: view, session: SSHShellSession(connectedChannel: channel))
        adapter.start()
        defer { adapter.stop() }
        let input = try XCTUnwrap(view as? any UITextInput)
        input.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0))
        input.insertText("中文e\u{301}")
        input.unmarkText() // UIKit may deliver this after insertText commits.
        input.unmarkText()
        input.setMarkedText("한국", selectedRange: NSRange(location: 2, length: 0))
        input.unmarkText() // This alternative UIKit commit must work as well.
        input.unmarkText()
        let received = await ghosttyWait { (await channel.snapshot()).sent.count == 2 }
        XCTAssertTrue(received)
        let snapshot = await channel.snapshot()
        XCTAssertEqual(snapshot.sent.map { Data($0) }, [Data("中文e\u{301}".utf8), Data("한국".utf8)])
        XCTAssertEqual(snapshot.readers, 1)
        XCTAssertEqual(snapshot.closes, 0)
        XCTAssertNil(input.markedTextRange)
        XCTAssertEqual(input.offset(from: input.beginningOfDocument, to: input.endOfDocument), 0)
    }

    func testUIKitDeleteEditsMarkedGraphemeButOnlyCommittedBackspaceSends() async throws {
        let channel = GhosttyVTTestPTY()
        let view = try GhosttyVTView()
        let adapter = GhosttyVTSessionAdapter(view: view, session: SSHShellSession(connectedChannel: channel))
        adapter.start()
        defer { adapter.stop() }
        let input = try XCTUnwrap(view as? any UITextInput)
        input.setMarkedText("中e\u{301}", selectedRange: NSRange(location: 3, length: 0))
        input.deleteBackward()
        XCTAssertEqual(input.markedTextRange.flatMap { input.text(in: $0) }, "中")
        input.setMarkedText(nil, selectedRange: .init(location: 0, length: 0))
        input.deleteBackward()
        input.insertText("\n")
        input.insertText("🧑🏽‍💻")
        let received = await ghosttyWait { (await channel.snapshot()).sent.count == 3 }
        XCTAssertTrue(received)
        let snapshot = await channel.snapshot()
        XCTAssertEqual(snapshot.sent.map { Data($0) }, [Data([127]), Data([13]), Data("🧑🏽‍💻".utf8)])
    }

    func testUIKitUTF16PositionsAndMarkedReplacementRemainLocalUntilCommit() async throws {
        let channel = GhosttyVTTestPTY()
        let view = try GhosttyVTView()
        let adapter = GhosttyVTSessionAdapter(view: view, session: SSHShellSession(connectedChannel: channel))
        adapter.start()
        defer { adapter.stop() }
        let input = try XCTUnwrap(view as? any UITextInput)
        input.setMarkedText("😀中", selectedRange: NSRange(location: 3, length: 0))
        XCTAssertEqual(input.offset(from: input.beginningOfDocument, to: input.endOfDocument), 3)
        let start = try XCTUnwrap(input.position(from: input.beginningOfDocument, offset: 2))
        let range = try XCTUnwrap(input.textRange(from: start, to: input.endOfDocument))
        XCTAssertEqual(input.text(in: range), "中")
        input.replace(range, withText: "文")
        XCTAssertEqual(input.markedTextRange.flatMap { input.text(in: $0) }, "😀文")
        XCTAssertNil(input.position(from: input.endOfDocument, offset: 1))
        input.unmarkText()
        let received = await ghosttyWait { (await channel.snapshot()).sent.count == 1 }
        XCTAssertTrue(received)
        let snapshot = await channel.snapshot()
        XCTAssertEqual(snapshot.sent, [Array("😀文".utf8)])
    }
}
