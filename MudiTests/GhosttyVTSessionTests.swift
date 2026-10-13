import Foundation
import GhosttyVt
import HerdrKit
import UIKit
import XCTest
@testable import Mudi

@MainActor
final class GhosttyVTSessionTests: XCTestCase {
    func testInputAndVTRepliesUseExistingPTYInOrder() async throws {
        let channel = GhosttyVTRecordingPTY()
        let session = SSHShellSession(connectedChannel: channel)
        let view = try GhosttyVTView(configuration: .init(columns: 20, rows: 4))
        let adapter = GhosttyVTSessionAdapter(view: view, session: session)
        var bells = 0
        var title: String?
        var directory: String?
        adapter.onBell = { bells += 1 }
        adapter.onTitleChange = { title = $0 }
        adapter.onWorkingDirectoryChange = { directory = $0 }
        var errors: [String] = []
        adapter.onError = { errors.append($0.localizedDescription) }
        adapter.start()
        adapter.start()
        defer { adapter.stop() }
        await channel.emit("hello\u{07}\u{1b}]2;Mudi VT\u{07}\u{1b}]7;file:///tmp\u{07}\u{1b}[5n\u{1b}[6n")
        let received = await wait { (await channel.snapshot()).sent.count == 2 }
        XCTAssertTrue(received, "VT-generated queries must be answered, not discarded as UI metadata")
        XCTAssertEqual(view.screen.text(at: 0).prefix(5), "hello")
        XCTAssertEqual(bells, 1)
        XCTAssertEqual(title, "Mudi VT")
        XCTAssertEqual(directory, "file:///tmp")
        try await adapter.sendCommittedText("中文e\u{301}")
        try await adapter.sendKey(.init(text: "c", modifiers: .control, unshiftedCodepoint: 99))
        try await adapter.sendKey(.init(key: .arrowUp))
        try await adapter.sendKey(.init(key: .tab, modifiers: .shift))
        try await adapter.sendKey(.init(key: .enter))
        await channel.emit("\u{1b}[?1h\u{1b}[?2004h")
        let applicationMode = await wait {
            (try? view.terminal.encode(.init(key: .arrowUp))) == Data("\u{1b}OA".utf8)
        }
        XCTAssertTrue(applicationMode)
        try await adapter.sendKey(.init(key: .arrowUp))
        try await adapter.paste("a\nb", appendEnter: true)
        let snapshot = await channel.snapshot()
        XCTAssertEqual(snapshot.outputReaders, 1, "Re-render/start must not create a second output consumer")
        XCTAssertEqual(snapshot.closeCount, 0)
        XCTAssertEqual(snapshot.sent.map { Data($0) }, [
            Data("\u{1b}[0n".utf8), Data("\u{1b}[1;6R".utf8),
            Data("中文e\u{301}".utf8), Data([3]), Data("\u{1b}[A".utf8),
            Data("\u{1b}[Z".utf8), Data([13]), Data("\u{1b}OA".utf8),
            Data("\u{1b}[200~a\nb\u{1b}[201~".utf8), Data([13]),
        ])
        XCTAssertTrue(errors.isEmpty, errors.joined(separator: ", "))
    }

    func testInitialAndVisibleGridResizeReachSameSessionWithoutDuplicateMount() async throws {
        let channel = GhosttyVTRecordingPTY()
        let session = SSHShellSession(connectedChannel: channel)
        let view = try GhosttyVTView(configuration: .init(columns: 20, rows: 4))
        // Pretend chrome has already reserved its bar/keyboard strip: this is
        // the surface's actual visible bounds, not the enclosing device frame.
        view.frame = CGRect(x: 0, y: 0, width: view.cellSize.width * 24 + 0.5,
                            height: view.cellSize.height * 6 + 0.5)
        view.layoutIfNeeded()
        let adapter = GhosttyVTSessionAdapter(view: view, session: session)
        adapter.start()
        defer { adapter.stop() }
        let first = await wait { (await channel.snapshot()).sizes.count == 1 }
        XCTAssertTrue(first)
        adapter.start()
        view.setNeedsLayout()
        view.layoutIfNeeded()
        view.frame.size.height = view.cellSize.height * 3 + 0.5
        view.setNeedsLayout()
        view.layoutIfNeeded()
        let resized = await wait { (await channel.snapshot()).sizes.count == 2 }
        XCTAssertTrue(resized)
        let snapshot = await channel.snapshot()
        XCTAssertEqual(snapshot.sizes, [.init(columns: 24, rows: 6), .init(columns: 24, rows: 3)])
        XCTAssertEqual(snapshot.outputReaders, 1)
        XCTAssertEqual(snapshot.closeCount, 0)
    }

    func testDetachedSurfaceContinuesParsingOverOneMiBWithoutRawByteDropQueue() async throws {
        let channel = GhosttyVTRecordingPTY()
        let view = try GhosttyVTView(configuration: .init(columns: 24, rows: 4, maxScrollback: 100))
        let session = SSHShellSession(connectedChannel: channel)
        let adapter = GhosttyVTSessionAdapter(view: view, session: session)
        adapter.start()
        defer { adapter.stop() }
        XCTAssertNil(view.window)
        // Unlike the rejected full-surface candidate there is no pre-attach
        // raw-byte queue: every output byte is fed while UIKit is detached.
        await channel.emit(String(repeating: "x", count: 1_048_580) + "\r\n最后e\u{301}\u{1b}[5n")
        let reply = await wait { (await channel.snapshot()).sent.count == 1 }
        XCTAssertTrue(reply)
        XCTAssertTrue(view.screen.rows.indices.contains { view.screen.text(at: $0).contains("最后e\u{301}") })
        XCTAssertGreaterThan(try view.terminal.status().scrollbackRows, 0)
        let snapshot = await channel.snapshot()
        XCTAssertEqual(snapshot.sent, [Array("\u{1b}[0n".utf8)])
    }

    func testSendFailureAndOutputEOFRemainObservable() async throws {
        let channel = GhosttyVTRecordingPTY()
        let session = SSHShellSession(connectedChannel: channel)
        let view = try GhosttyVTView()
        let adapter = GhosttyVTSessionAdapter(view: view, session: session)
        var errors = 0
        var closed = 0
        adapter.onError = { _ in errors += 1 }
        adapter.onClosed = { closed += 1 }
        adapter.start()
        defer { adapter.stop() }
        await channel.failWrites()
        do {
            try await adapter.sendCommittedText("unsent")
            XCTFail("A failed PTY send must propagate an actual error")
        } catch {
            XCTAssertTrue(error is GhosttyVTRecordingPTY.WriteError,
                          "The input caller needs the actual PTY error, not an opaque adapter wrapper")
        }
        XCTAssertEqual(errors, 1)
        await channel.finish()
        let didClose = await wait { closed == 1 }
        XCTAssertTrue(didClose)
        let snapshot = await channel.snapshot()
        XCTAssertEqual(snapshot.closeCount, 1)
    }

    func testStoppingAdapterDoesNotCloseOrReconnectOriginalSession() async throws {
        let channel = GhosttyVTRecordingPTY()
        let session = SSHShellSession(connectedChannel: channel)
        let adapter = GhosttyVTSessionAdapter(view: try GhosttyVTView(), session: session)
        adapter.start()
        let attached = await wait { (await channel.snapshot()).outputReaders == 1 }
        XCTAssertTrue(attached)
        adapter.stop()
        try await session.send([42])
        let snapshot = await channel.snapshot()
        XCTAssertEqual(snapshot.closeCount, 0)
        XCTAssertEqual(snapshot.sent, [[42]])
    }

    func testInputBeforeStartReportsNotStartedRatherThanCancellation() async throws {
        let channel = GhosttyVTRecordingPTY()
        let adapter = GhosttyVTSessionAdapter(view: try GhosttyVTView(),
                                             session: SSHShellSession(connectedChannel: channel))
        do {
            try await adapter.sendCommittedText("not bound")
            XCTFail("An unstarted renderer must not send input")
        } catch {
            XCTAssertTrue(error is GhosttyVTSessionAdapter.AdapterError)
        }
        let snapshot = await channel.snapshot()
        XCTAssertTrue(snapshot.sent.isEmpty)
        XCTAssertEqual(snapshot.outputReaders, 0)
    }

    func testQueuedInputCannotOvertakeSuspendedPTYWrite() async throws {
        let channel = GhosttyVTRecordingPTY()
        let adapter = GhosttyVTSessionAdapter(view: try GhosttyVTView(),
                                             session: SSHShellSession(connectedChannel: channel))
        adapter.start()
        defer { adapter.stop() }
        await channel.delayNextWrite()
        let first = Task { try await adapter.sendCommittedText("first") }
        let firstStarted = await wait { (await channel.snapshot()).attempted.count == 1 }
        XCTAssertTrue(firstStarted)
        let second = Task { try await adapter.paste("second", appendEnter: true) }
        try await first.value
        try await second.value
        let snapshot = await channel.snapshot()
        XCTAssertEqual(snapshot.sent.map { Data($0) }, [Data("first".utf8), Data("second".utf8), Data([13])])
        XCTAssertEqual(snapshot.attempted, snapshot.sent,
                       "Even a reentrant PTY cannot overtake the previous send or split paste/Enter")
    }

    func testInvalidInitializationIsARealObservableFailure() throws {
        XCTAssertThrowsError(try GhosttyVTView(configuration: .init(columns: 0, rows: 24))) {
            XCTAssertEqual($0 as? TerminalError, .invalidSize)
        }
    }

    private func wait(_ observation: () async -> Bool) async -> Bool {
        for _ in 0..<200 {
            if await observation() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await observation()
    }
}

/// Only the PTY transport is recorded. The engine, effects and UIKit renderer
/// are the actual production implementations, not fake cells/parser/replies.
private actor GhosttyVTRecordingPTY: PTYOutputChannel {
    struct Snapshot: Sendable {
        let sent: [[UInt8]]
        let attempted: [[UInt8]]
        let sizes: [GhosttyVt.Terminal.Size]
        let outputReaders: Int
        let closeCount: Int
    }
    enum WriteError: Error { case disconnected }
    private let stream: AsyncThrowingStream<[UInt8], Error>
    private let continuation: AsyncThrowingStream<[UInt8], Error>.Continuation
    private var sent: [[UInt8]] = []
    private var attempted: [[UInt8]] = []
    private var shouldDelayWrite = false
    private var sizes: [GhosttyVt.Terminal.Size] = []
    private var outputReaders = 0
    private var closeCount = 0
    private var writesFail = false

    init() {
        (stream, continuation) = AsyncThrowingStream.makeStream()
    }
    func outputStream() -> AsyncThrowingStream<[UInt8], Error> { outputReaders += 1; return stream }
    func send(_ bytes: [UInt8]) async throws {
        attempted.append(bytes)
        if writesFail { throw WriteError.disconnected }
        if shouldDelayWrite {
            shouldDelayWrite = false
            try await Task.sleep(for: .milliseconds(40))
        }
        sent.append(bytes)
    }
    func resize(columns: Int, rows: Int) {
        sizes.append(.init(columns: UInt16(columns), rows: UInt16(rows)))
    }
    func close() { closeCount += 1; continuation.finish() }
    func emit(_ text: String) { continuation.yield(Array(text.utf8)) }
    func finish() { continuation.finish() }
    func failWrites() { writesFail = true }
    func delayNextWrite() { shouldDelayWrite = true }
    func snapshot() -> Snapshot {
        .init(sent: sent, attempted: attempted, sizes: sizes, outputReaders: outputReaders, closeCount: closeCount)
    }
}
