import GhosttyVt
import HerdrKit
import UIKit
import XCTest
@testable import Mudi

@MainActor
final class GhosttyVTViewportTests: XCTestCase {
    func testLocalScrollbackUsesRealVTViewportAndDoesNotSendInput() async throws {
        let channel = GhosttyVTTestPTY()
        let view = try GhosttyVTView(configuration: .init(columns: 20, rows: 3))
        let interactions = try XCTUnwrap(view as? any TerminalViewportInteractions)
        let adapter = GhosttyVTSessionAdapter(view: view, session: SSHShellSession(connectedChannel: channel))
        adapter.start()
        defer { adapter.stop() }
        await channel.emit((1...20).map { "line \($0)" }.joined(separator: "\r\n") + "\r\nBOTTOM")
        let received = await ghosttyWait { view.screen.text(at: 2).contains("BOTTOM") }
        XCTAssertTrue(received)
        let before = view.screen.rows
        XCTAssertGreaterThan(try view.terminal.status().scrollbackRows, 0)
        interactions.scrollTerminal(direction: .up, lines: 10, location: .zero)
        XCTAssertFalse(try view.terminal.status().isViewportActive)
        XCTAssertNotEqual(view.screen.rows, before)
        XCTAssertTrue(view.screen.text(at: 0).contains("line"))
        interactions.scrollTerminal(direction: .down, lines: 1000, location: .zero)
        XCTAssertTrue(try view.terminal.status().isViewportActive)
        XCTAssertEqual(view.screen.rows, before)
        let snapshot = await channel.snapshot()
        XCTAssertTrue(snapshot.sent.isEmpty)
        XCTAssertEqual(snapshot.readers, 1)
        XCTAssertEqual(snapshot.closes, 0)
    }

    func testVTCellSelectionAndUIKitCopyPasteDoNotSplitWideOrCombiningCells() async throws {
        let channel = GhosttyVTTestPTY()
        let view = try GhosttyVTView(configuration: .init(columns: 12, rows: 3))
        let interactions = try XCTUnwrap(view as? any TerminalViewportInteractions)
        let adapter = GhosttyVTSessionAdapter(view: view, session: SSHShellSession(connectedChannel: channel))
        adapter.start()
        defer { adapter.stop() }
        _ = try view.feed(Data("界e\u{301} abc\r\nnext\u{1b}[?2004h\u{1b}[?25l".utf8))
        interactions.selectTerminalCells(from: .init(column: 1, row: 0), through: .init(column: 2, row: 0))
        XCTAssertEqual(interactions.selectedTerminalText, "界e\u{301}")
        XCTAssertTrue(view.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)), withSender: nil))
        let oldClipboard = UIPasteboard.general.string
        defer { UIPasteboard.general.string = oldClipboard }
        _ = view.perform(#selector(UIResponderStandardEditActions.copy(_:)), with: nil)
        XCTAssertEqual(UIPasteboard.general.string, "界e\u{301}")
        _ = view.perform(#selector(UIResponderStandardEditActions.paste(_:)), with: nil)
        let pasted = await ghosttyWait { !(await channel.snapshot()).sent.isEmpty }
        XCTAssertTrue(pasted)
        let snapshot = await channel.snapshot()
        XCTAssertEqual(snapshot.sent, [Array("\u{1b}[200~界e\u{301}\u{1b}[201~".utf8)])
        interactions.clearTerminalSelection()
        XCTAssertNil(interactions.selectedTerminalText)
        XCTAssertFalse(view.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)), withSender: nil))
        let presses = (view.gestureRecognizers ?? []).compactMap { $0 as? UILongPressGestureRecognizer }
        XCTAssertTrue(presses.contains { $0.numberOfTapsRequired == 0 }, "Real UIKit text-selection long press")
        XCTAssertTrue(presses.contains { $0.numberOfTapsRequired == 1 }, "ThumbArc keeps its separate second-tap hold")
        XCTAssertTrue((view.gestureRecognizers ?? []).contains { $0 is UIPanGestureRecognizer })
        let image = UIGraphicsImageRenderer(size: CGSize(width: view.cellSize.width * 12, height: view.cellSize.height * 3)).image { _ in
            view.frame.size = CGSize(width: view.cellSize.width * 12, height: view.cellSize.height * 3)
            interactions.selectTerminalCells(from: .init(column: 1, row: 0), through: .init(column: 2, row: 0))
            view.draw(view.bounds)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "GhosttyVT-UIKit-cell-selection"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(interactions.selectedTerminalText, "界e\u{301}")
    }

    func testHostScrollbackOwnsScrollWithoutLocalMovementOrANSIInput() async throws {
        let channel = GhosttyVTTestScrollPTY()
        let view = try GhosttyVTView(configuration: .init(columns: 20, rows: 3))
        let interactions = try XCTUnwrap(view as? any TerminalViewportInteractions)
        let adapter = GhosttyVTSessionAdapter(view: view, session: SSHShellSession(connectedChannel: channel))
        adapter.start()
        defer { adapter.stop() }
        let ready = await ghosttyWait { interactions.scrollCapability == .hostScrollback }
        XCTAssertTrue(ready)
        _ = try view.feed(Data((1...10).map { "host \($0)" }.joined(separator: "\r\n").utf8))
        let before = view.screen.rows
        interactions.scrollTerminal(direction: .up, lines: 4, location: .zero)
        let scrolled = await ghosttyWait { await channel.requests().count == 1 }
        XCTAssertTrue(scrolled)
        let requests = await channel.requests()
        XCTAssertEqual(requests.map(\.direction), [.up])
        XCTAssertEqual(requests.map(\.lines), [4])
        XCTAssertEqual(view.screen.rows, before)
        XCTAssertTrue(try view.terminal.status().isViewportActive)
        let snapshot = await channel.recording.snapshot()
        XCTAssertTrue(snapshot.sent.isEmpty)
    }

    func testRemoteWheelUsesVTMouseModeEncodingAndVisibleCellCoordinatesOnly() async throws {
        let channel = GhosttyVTTestWheelPTY()
        let view = try GhosttyVTView(configuration: .init(columns: 20, rows: 3))
        let interactions = try XCTUnwrap(view as? any TerminalViewportInteractions)
        let adapter = GhosttyVTSessionAdapter(view: view, session: SSHShellSession(connectedChannel: channel))
        adapter.start()
        defer { adapter.stop() }
        let ready = await ghosttyWait { interactions.scrollCapability == .remoteMouseWheel }
        XCTAssertTrue(ready)
        view.frame.size = CGSize(width: view.cellSize.width * 20, height: view.cellSize.height * 3)
        _ = try view.feed(Data("\u{1b}[?1000h\u{1b}[?1006h".utf8))
        let location = CGPoint(x: view.cellSize.width * 2.5, y: view.cellSize.height * 1.5)
        interactions.scrollTerminal(direction: .up, lines: 2, location: location)
        let sent = await ghosttyWait { (await channel.recording.snapshot()).sent.count == 2 }
        XCTAssertTrue(sent)
        let snapshot = await channel.recording.snapshot()
        XCTAssertEqual(snapshot.sent, [Array("\u{1b}[<64;3;2M".utf8), Array("\u{1b}[<64;3;2M".utf8)])
        _ = try view.feed(Data("\u{1b}[?1000l".utf8))
        interactions.scrollTerminal(direction: .down, lines: 8, location: location)
        try await Task.sleep(for: .milliseconds(30))
        let disabled = await channel.recording.snapshot()
        XCTAssertEqual(disabled.sent, snapshot.sent,
                       "Wheel owner with disabled mouse mode must NOT silently switch to local history")
        XCTAssertTrue(try view.terminal.status().isViewportActive)
        adapter.stop()
        interactions.scrollTerminal(direction: .up, lines: 8, location: location)
        try await Task.sleep(for: .milliseconds(20))
        let stopped = await channel.recording.snapshot()
        XCTAssertEqual(stopped.sent, snapshot.sent)
    }
}

actor GhosttyVTTestScrollPTY: PTYScrollChannel, PTYOutputChannel {
    struct Request: Sendable { let direction: TerminalScrollDirection; let lines: Int }
    let recording = GhosttyVTTestPTY()
    private var scrolls: [Request] = []
    func requests() -> [Request] { scrolls }
    func scroll(direction: TerminalScrollDirection, lines: Int) async throws { scrolls.append(.init(direction: direction, lines: lines)) }
    func send(_ bytes: [UInt8]) async throws { try await recording.send(bytes) }
    func resize(columns: Int, rows: Int) async throws { try await recording.resize(columns: columns, rows: rows) }
    func close() async { await recording.close() }
    func outputStream() async -> AsyncThrowingStream<[UInt8], Error> { await recording.outputStream() }
}

actor GhosttyVTTestWheelPTY: PTYWheelInputChannel, PTYOutputChannel {
    let recording = GhosttyVTTestPTY()
    var acceptsMouseWheelInput: Bool { true }
    func send(_ bytes: [UInt8]) async throws { try await recording.send(bytes) }
    func resize(columns: Int, rows: Int) async throws { try await recording.resize(columns: columns, rows: rows) }
    func close() async { await recording.close() }
    func outputStream() async -> AsyncThrowingStream<[UInt8], Error> { await recording.outputStream() }
}
