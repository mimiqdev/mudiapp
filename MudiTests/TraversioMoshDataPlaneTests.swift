import Foundation
import HerdrKit
import TraversioMoshBootstrap
import TraversioMoshCore
import XCTest
@preconcurrency import SwiftTerm
@testable import Mudi

@MainActor
final class MoshScreenFrameRendererTests: XCTestCase {
    func testRenderedFrameReproducesSnapshotText() throws {
        let frame = render(
            try makeSnapshot(feed: "hello")
        )
        let terminal = makeTerminal(cols: 20, rows: 6)

        terminal.feed(byteArray: frame)

        XCTAssertEqual(lineText(terminal, 0), "hello")
    }

    /// A rendered frame is a complete replacement: feeding it after a frame
    /// with different content must not leave the old glyphs behind. This is
    /// the exact failure mode (duplicated/garbled glyphs) the byte-append
    /// restore path produced.
    func testRenderedFrameReplacesPreviousFrameWithoutResidue() throws {
        let first = render(
            try makeSnapshot(feed: "AAAA")
        )
        let secondSnapshot = try makeSnapshot(feed: "\u{1b}[2J\u{1b}[HB")
        let second = render(secondSnapshot)
        let terminal = makeTerminal(cols: 20, rows: 6)

        terminal.feed(byteArray: first)
        XCTAssertEqual(lineText(terminal, 0), "AAAA")

        terminal.feed(byteArray: second)
        XCTAssertEqual(lineText(terminal, 0), "B")
        XCTAssertFalse(
            screenText(terminal).contains("AAAA"),
            "A replacement frame must not retain the previous frame's glyphs"
        )
    }

    /// Replaying the same complete frame must be idempotent. An adapter that
    /// appended diffs would double the glyphs on every repaint.
    func testRenderingTheSameFrameTwiceDoesNotDuplicateGlyphs() throws {
        let snapshot = try makeSnapshot(feed: "B")
        let frame = render(snapshot)
        let terminal = makeTerminal(cols: 20, rows: 6)

        terminal.feed(byteArray: frame)
        terminal.feed(byteArray: frame)
        terminal.feed(byteArray: frame)

        XCTAssertEqual(lineText(terminal, 0), "B")
        XCTAssertEqual(
            screenText(terminal).filter { $0 == "B" }.count,
            1
        )
    }

    func testRenderedFrameKeepsWideCharactersAligned() throws {
        let frame = render(
            try makeSnapshot(feed: "中x")
        )
        let terminal = makeTerminal(cols: 20, rows: 6)

        terminal.feed(byteArray: frame)

        XCTAssertEqual(lineText(terminal, 0), "中x")
        XCTAssertEqual(
            terminal.getCharData(col: 0, row: 0)?.getCharacter(),
            "中"
        )
        XCTAssertEqual(
            terminal.getCharData(col: 2, row: 0)?.getCharacter(),
            "x"
        )
    }

    func testRenderedFrameMapsTextAttributesAndColors() throws {
        let frame = render(
            try makeSnapshot(
                feed: "\u{1b}[1;3;4;7;38;2;10;20;30;48;5;200mZ"
            )
        )
        let terminal = makeTerminal(cols: 20, rows: 6)

        terminal.feed(byteArray: frame)

        let cell = try XCTUnwrap(terminal.getCharData(col: 0, row: 0))
        XCTAssertTrue(cell.attribute.style.contains(.bold))
        XCTAssertTrue(cell.attribute.style.contains(.italic))
        XCTAssertTrue(
            cell.attribute.style.contains(.underline)
                || cell.attribute.underlineStyle != .none,
            "Underline must survive the snapshot round trip"
        )
        XCTAssertTrue(cell.attribute.style.contains(.inverse))
        XCTAssertEqual(
            cell.attribute.fg,
            .trueColor(red: 10, green: 20, blue: 30)
        )
        XCTAssertEqual(cell.attribute.bg, .ansi256(code: 200))
    }

    func testRenderedFramePositionsCursorAndVisibility() throws {
        let terminal = makeTerminal(cols: 20, rows: 6)

        terminal.feed(
            byteArray: render(
                try makeSnapshot(feed: "\u{1b}[3;5H")
            )
        )
        XCTAssertEqual(terminal.buffer.x, 4)
        XCTAssertEqual(terminal.buffer.y, 2)

        let hidden = try makeSnapshot(feed: "\u{1b}[?25l")
        XCTAssertFalse(hidden.isCursorVisible)
        terminal.feed(byteArray: render(hidden))
        let line = try XCTUnwrap(terminal.getLine(row: 0))
        XCTAssertEqual(line.count, 20)
    }

    func testRenderedFramePropagatesApplicationCursorAndMouseModes() throws {
        let frame = render(
            try makeSnapshot(
                feed: "\u{1b}[?1h\u{1b}[?1002h\u{1b}[?1006h"
            )
        )
        let terminal = makeTerminal(cols: 20, rows: 6)

        terminal.feed(byteArray: frame)

        XCTAssertTrue(terminal.applicationCursor)
        XCTAssertEqual(terminal.mouseMode, .buttonEventTracking)
    }

    /// Bright ANSI colors must keep their color offset: SGR 91 is bright red,
    /// not bright black. The renderer previously emitted `90` for every bright
    /// foreground because it dropped `ansiColor.rawValue` in the bright branch.
    func testRenderedFrameKeepsBrightANSIColors() throws {
        let frame = render(
            try makeSnapshot(feed: "\u{1b}[91;101mR")
        )
        let terminal = makeTerminal(cols: 20, rows: 6)

        terminal.feed(byteArray: frame)

        let cell = try XCTUnwrap(terminal.getCharData(col: 0, row: 0))
        XCTAssertEqual(cell.attribute.fg, .ansi256(code: 9))
        XCTAssertEqual(cell.attribute.bg, .ansi256(code: 9))
    }

    func testRenderedFrameForwardsHyperlinkRuns() throws {
        let frame = render(
            try makeSnapshot(
                feed: "\u{1b}]8;;https://example.com\u{1b}\\L\u{1b}]8;;\u{1b}\\X"
            )
        )
        let terminal = makeTerminal(cols: 20, rows: 6)

        terminal.feed(byteArray: frame)

        let linkedCell = try XCTUnwrap(terminal.getCharData(col: 0, row: 0))
        XCTAssertTrue(
            linkedCell.hasPayload,
            "The hyperlink cell must carry the OSC 8 payload"
        )
        let plainCell = try XCTUnwrap(terminal.getCharData(col: 1, row: 0))
        XCTAssertFalse(
            plainCell.hasPayload,
            "Closing the hyperlink must stop the payload at the run boundary"
        )
    }

    /// Bells are counters in the snapshot, so the renderer emits BEL only for
    /// the delta since the previous frame. The first frame establishes the
    /// baseline and never replays history.
    func testRendererEmitsBellOnBellCountIncrease() throws {
        var screen = try makeScreen()
        _ = try screen.apply(
            MoshTerminalOutput(bytes: Array("prompt".utf8))
        )
        var renderer = MoshScreenFrameRenderer()
        let baseline = renderer.render(screen.snapshot)
        XCTAssertFalse(baseline.controlBytes.contains(0x07))

        _ = try screen.apply(MoshTerminalOutput(bytes: [0x07]))
        let ring = renderer.render(screen.snapshot)
        XCTAssertTrue(ring.controlBytes.contains(0x07))

        let stable = renderer.render(screen.snapshot)
        XCTAssertFalse(
            stable.controlBytes.contains(0x07),
            "A snapshot with no new bell must not re-ring"
        )
    }

    func testRendererForwardsTitleChanges() throws {
        var screen = try makeScreen()
        var renderer = MoshScreenFrameRenderer()

        _ = try screen.apply(
            MoshTerminalOutput(bytes: Array("\u{1b}]2;mudi\u{7}".utf8))
        )
        let first = renderer.render(screen.snapshot)
        XCTAssertEqual(screen.snapshot.windowTitle, "mudi")
        XCTAssertEqual(
            delegateTitle(from: first.controlBytes),
            "mudi",
            "The initial title must reach SwiftTerm"
        )

        _ = try screen.apply(
            MoshTerminalOutput(bytes: Array("\u{1b}]2;herdr\u{7}".utf8))
        )
        let second = renderer.render(screen.snapshot)
        XCTAssertEqual(delegateTitle(from: second.controlBytes), "herdr")

        let stable = renderer.render(screen.snapshot)
        XCTAssertNil(
            delegateTitle(from: stable.controlBytes),
            "An unchanged title must not be re-emitted"
        )
    }

    // MARK: Helpers

    private func render(_ snapshot: MoshTerminalScreenSnapshot) -> [UInt8] {
        var renderer = MoshScreenFrameRenderer()
        return renderer.render(snapshot).bytes
    }

    private func makeScreen(
        cols: Int = 20,
        rows: Int = 6
    ) throws -> MoshTerminalScreen {
        MoshTerminalScreen(
            dimensions: try MoshTerminalDimensions(
                columns: Int32(cols),
                rows: Int32(rows)
            )
        )
    }

    private func makeSnapshot(
        cols: Int = 20,
        rows: Int = 6,
        feed: String
    ) throws -> MoshTerminalScreenSnapshot {
        var screen = try makeScreen(cols: cols, rows: rows)
        _ = try screen.apply(
            MoshTerminalOutput(bytes: Array(feed.utf8))
        )
        return screen.snapshot
    }

    /// Parses the first OSC 2 title out of a rendered frame, as SwiftTerm's
    /// delegate would observe it.
    private func delegateTitle(from frame: [UInt8]) -> String? {
        guard let text = String(bytes: frame, encoding: .utf8),
              let oscRange = text.range(of: "\u{1b}]2;")
        else { return nil }
        let remainder = text[oscRange.upperBound...]
        guard let end = remainder.range(of: "\u{1b}\\") else { return nil }
        return String(remainder[..<end.lowerBound])
    }

    private func makeTerminal(cols: Int, rows: Int) -> Terminal {
        let delegate = TestTerminalDelegate()
        let terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(
                cols: cols,
                rows: rows,
                scrollback: 0
            )
        )
        terminalDelegates.append(delegate)
        return terminal
    }

    private func lineText(_ terminal: Terminal, _ row: Int) -> String {
        let raw = terminal.getLine(row: row)?.translateToString(
            trimRight: false,
            skipNullCellsFollowingWide: true
        ) ?? ""
        return String(
            raw.reversed().drop { $0 == " " || $0 == "\0" }.reversed()
        )
    }

    private func screenText(_ terminal: Terminal) -> String {
        (0..<terminal.rows)
            .map { lineText(terminal, $0) }
            .joined(separator: "\n")
    }

    private var terminalDelegates: [TestTerminalDelegate] = []
}

final class TestTerminalDelegate: TerminalDelegate {
    private(set) var isCursorVisible = true

    func send(source _: Terminal, data _: ArraySlice<UInt8>) {}

    func showCursor(source _: Terminal) {
        isCursorVisible = true
    }

    func hideCursor(source _: Terminal) {
        isCursorVisible = false
    }
}

@MainActor
final class MoshSnapshotChannelTests: XCTestCase {
    func testChannelEmitsFullFrameForEveryRenderOperation() async throws {
        let first = try makeSnapshot(feed: "first")
        let second = try makeSnapshot(feed: "\u{1b}[2J\u{1b}[Hsecond")
        let session = TestTraversioMoshSession(
            endpoint: try makeEndpoint(),
            dimensions: try MoshTerminalDimensions(columns: 20, rows: 6),
            snapshot: first
        )
        let channel = MoshPTYChannel(session: session)
        let stream = await channel.outputStream()
        var iterator = stream.makeAsyncIterator()

        await session.publish(
            .write(MoshTerminalOutput(bytes: Array("first".utf8))),
            snapshot: first
        )
        let firstFrame = try await iterator.next()

        await session.publish(
            .write(MoshTerminalOutput(bytes: Array("second".utf8))),
            snapshot: second
        )
        let secondFrame = try await iterator.next()

        let terminal = makeTerminal()
        terminal.feed(byteArray: try XCTUnwrap(firstFrame))
        XCTAssertEqual(lineText(terminal, 0), "first")
        terminal.feed(byteArray: try XCTUnwrap(secondFrame))
        XCTAssertEqual(lineText(terminal, 0), "second")
        XCTAssertEqual(
            (0..<terminal.rows)
                .map { lineText(terminal, $0) }
                .joined()
                .contains("first"),
            false,
            "Late frames must replace the displayed frame, not append to it"
        )

        await channel.close()
    }

    /// The channel owns the renderer across frames, so a bell counted between
    /// two render operations still reaches the output as a BEL in the second
    /// frame.
    func testChannelKeepsRendererStateAcrossFrames() async throws {
        var screen = MoshTerminalScreen(
            dimensions: try MoshTerminalDimensions(columns: 20, rows: 6)
        )
        _ = try screen.apply(MoshTerminalOutput(bytes: Array("x".utf8)))
        let baseline = screen.snapshot
        let session = TestTraversioMoshSession(
            endpoint: try makeEndpoint(),
            dimensions: try MoshTerminalDimensions(columns: 20, rows: 6),
            snapshot: baseline
        )
        let channel = MoshPTYChannel(session: session)
        let stream = await channel.outputStream()
        var iterator = stream.makeAsyncIterator()

        await session.publish(
            .write(MoshTerminalOutput(bytes: [0x78])),
            snapshot: baseline
        )
        let firstFrame = try await iterator.next()
        XCTAssertFalse(
            try XCTUnwrap(firstFrame).contains(0x07),
            "The first frame is the bell baseline"
        )

        _ = try screen.apply(MoshTerminalOutput(bytes: [0x07]))
        let withBell = screen.snapshot
        await session.publish(
            .write(MoshTerminalOutput(bytes: [0x07])),
            snapshot: withBell
        )
        let secondFrame = try await iterator.next()
        XCTAssertTrue(
            try XCTUnwrap(secondFrame).contains(0x07),
            "A bell after the baseline must be emitted"
        )

        await channel.close()
    }

    /// Display frames are latest-only, but a bell/title signal must survive a
    /// frame evicted by `.bufferingNewest(1)`: the channel re-attaches the
    /// evicted frame's control bytes to the next delivered frame. This test
    /// publishes while no consumer is reading, then consumes only the latest
    /// buffered frame.
    func testChannelRetainsControlSignalsFromEvictedFrames() async throws {
        var screen = MoshTerminalScreen(
            dimensions: try MoshTerminalDimensions(columns: 20, rows: 6)
        )
        _ = try screen.apply(MoshTerminalOutput(bytes: Array("x".utf8)))
        let baseline = screen.snapshot
        let session = TestTraversioMoshSession(
            endpoint: try makeEndpoint(),
            dimensions: try MoshTerminalDimensions(columns: 20, rows: 6),
            snapshot: baseline
        )
        let channel = MoshPTYChannel(session: session)
        let stream = await channel.outputStream()
        var iterator = stream.makeAsyncIterator()

        // No consumer yet: each new frame evicts the previous one.
        await session.publish(
            .write(MoshTerminalOutput(bytes: [0x78])),
            snapshot: baseline
        )
        try await Task.sleep(for: .milliseconds(60))

        _ = try screen.apply(MoshTerminalOutput(bytes: [0x07]))
        let withBell = screen.snapshot
        await session.publish(
            .write(MoshTerminalOutput(bytes: [0x07])),
            snapshot: withBell
        )
        try await Task.sleep(for: .milliseconds(60))

        // A later frame with no new bell must still carry the evicted bell.
        await session.publish(
            .write(MoshTerminalOutput(bytes: Array("y".utf8))),
            snapshot: withBell
        )
        try await Task.sleep(for: .milliseconds(60))

        let nextFrame = try await iterator.next()
        let delivered = try XCTUnwrap(nextFrame)
        XCTAssertTrue(
            delivered.contains(0x07),
            "A bell from an evicted frame must be re-attached to the next delivered frame"
        )

        await channel.close()
    }

    func testChannelMapsInputResizeAndCloseToTheSession() async throws {
        let snapshot = try makeSnapshot(feed: "x")
        let session = TestTraversioMoshSession(
            endpoint: try makeEndpoint(),
            dimensions: try MoshTerminalDimensions(columns: 20, rows: 6),
            snapshot: snapshot
        )
        let channel = MoshPTYChannel(session: session)

        try await channel.send([0x61, 0x62])
        try await channel.resize(columns: 100, rows: 30)

        let sent = await session.sentBytes()
        XCTAssertEqual(sent, [[0x61, 0x62]])
        let resizes = await session.resizeCalls()
        XCTAssertEqual(resizes.count, 1)
        XCTAssertEqual(resizes.first?.columns, 100)
        XCTAssertEqual(resizes.first?.rows, 30)
        let stoppedAfterResize = await session.isStopped()
        XCTAssertFalse(stoppedAfterResize)

        await channel.close()

        let stoppedAfterClose = await session.isStopped()
        XCTAssertTrue(stoppedAfterClose)
        do {
            try await channel.send([0x63])
            XCTFail("A closed Mosh channel must reject input")
        } catch let error as MoshSessionChannelError {
            XCTAssertEqual(error, .closed)
        }
    }

    private func makeSnapshot(feed: String) throws -> MoshTerminalScreenSnapshot {
        var screen = MoshTerminalScreen(
            dimensions: try MoshTerminalDimensions(columns: 20, rows: 6)
        )
        _ = try screen.apply(MoshTerminalOutput(bytes: Array(feed.utf8)))
        return screen.snapshot
    }

    private func makeEndpoint() throws -> MoshEndpoint {
        let bootstrap = try MoshBootstrapParser.parse(
            "MOSH CONNECT 60001 GE0sKFO189zPL+rA0/xACg"
        )
        return MoshEndpoint(
            host: "127.0.0.1",
            port: bootstrap.port,
            sessionKey: bootstrap.sessionKey
        )
    }

    private func makeTerminal() -> Terminal {
        let delegate = TestTerminalDelegate()
        let terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(cols: 20, rows: 6, scrollback: 0)
        )
        terminalDelegates.append(delegate)
        return terminal
    }

    private func lineText(_ terminal: Terminal, _ row: Int) -> String {
        let raw = terminal.getLine(row: row)?.translateToString(
            trimRight: false,
            skipNullCellsFollowingWide: true
        ) ?? ""
        return String(
            raw.reversed().drop { $0 == " " || $0 == "\0" }.reversed()
        )
    }

    private var terminalDelegates: [TestTerminalDelegate] = []
}

@MainActor
final class TraversioMoshAdapterTests: XCTestCase {
    private static let bootstrapOutput = """
    Warning: SSH_CONNECTION not found; binding to any interface.

    [mosh-server detached, pid = 95522]
    MOSH CONNECT 60001 GE0sKFO189zPL+rA0/xACg
    """

    func testServerCommandKeepsLoginShellAndStderrMerge() {
        let login = TraversioMoshAdapter.serverCommand(for: nil)
        XCTAssertTrue(
            login.contains("mosh-server new -s 2>&1"),
            "Login-shell mosh-server must merge stderr so the pid line is captured"
        )
        let attach = TraversioMoshAdapter.serverCommand(
            for: "exec herdr terminal attach term_65a1d4135cfa21 --takeover"
        )
        XCTAssertTrue(attach.contains("2>&1"))
        XCTAssertTrue(attach.contains("mosh-server new -s --"))
        XCTAssertFalse(attach.contains("herdr terminal attach --takeover"))
    }

    func testConnectParsesBootstrapAndMountsTraversioSession() async throws {
        let bootstrap = TestMoshBootstrapChannel(
            output: Array(Self.bootstrapOutput.utf8)
        )
        let bootstrapSession = SSHShellSession(connectedChannel: bootstrap)
        let box = MoshSessionBox()
        let adapter = TraversioMoshAdapter(makeSession: { endpoint, dimensions in
            let session = TestTraversioMoshSession(
                endpoint: endpoint,
                dimensions: dimensions,
                snapshot: Self.placeholderSnapshot(dimensions: dimensions)
            )
            box.append(session)
            return session
        })

        let terminalSession = try await adapter.connect(
            to: phase9Host(),
            credentials: phase2Credentials(),
            using: bootstrapSession,
            command: "exec herdr terminal attach term_65a1d4135cfa21 --takeover"
        )

        let created = try XCTUnwrap(box.first())
        let recordedEndpoint = await created.recordedEndpoint()
        XCTAssertEqual(recordedEndpoint.port, 60001)
        XCTAssertEqual(recordedEndpoint.host, "phase9.example.test")
        let recordedDimensions = await created.recordedDimensions()
        XCTAssertEqual(
            recordedDimensions,
            try MoshTerminalDimensions(columns: 80, rows: 24)
        )
        let started = await created.isStarted()
        XCTAssertTrue(started)

        let executed = await bootstrap.executedCommands()
        XCTAssertEqual(executed.count, 1)
        XCTAssertTrue(
            try XCTUnwrap(executed.first)
                .contains("mosh-server new -s --")
        )
        XCTAssertTrue(
            try XCTUnwrap(executed.first).contains("2>&1")
        )

        // The channel returned by the adapter drives the Traversio session.
        try await terminalSession.send([0x61])
        let sent = await created.sentBytes()
        XCTAssertEqual(sent, [[0x61]])
        try await terminalSession.resize(columns: 90, rows: 31)
        let resizes = await created.resizeCalls()
        XCTAssertEqual(resizes.count, 1)
        XCTAssertEqual(resizes.first?.columns, 90)
        XCTAssertEqual(resizes.first?.rows, 31)

        await adapter.disconnect()
        let stopped = await created.isStopped()
        XCTAssertTrue(stopped)
    }

    func testConnectStopsThePreviousSession() async throws {
        let bootstrap = TestMoshBootstrapChannel(
            output: Array(Self.bootstrapOutput.utf8)
        )
        let bootstrapSession = SSHShellSession(connectedChannel: bootstrap)
        let box = MoshSessionBox()
        let adapter = TraversioMoshAdapter(makeSession: { endpoint, dimensions in
            let session = TestTraversioMoshSession(
                endpoint: endpoint,
                dimensions: dimensions,
                snapshot: Self.placeholderSnapshot(dimensions: dimensions)
            )
            box.append(session)
            return session
        })

        _ = try await adapter.connect(
            to: phase9Host(),
            credentials: phase2Credentials(),
            using: bootstrapSession
        )
        let first = try XCTUnwrap(box.first())
        _ = try await adapter.connect(
            to: phase9Host(),
            credentials: phase2Credentials(),
            using: bootstrapSession
        )
        let second = try XCTUnwrap(box.last())

        let firstStopped = await first.isStopped()
        let secondStopped = await second.isStopped()
        XCTAssertTrue(firstStopped)
        XCTAssertFalse(secondStopped)
    }

    func testLeaveTerminatesCapturedDaemonPid() async throws {
        let bootstrap = TestMoshBootstrapChannel(
            output: Array(Self.bootstrapOutput.utf8)
        )
        let bootstrapSession = SSHShellSession(connectedChannel: bootstrap)
        let adapter = TraversioMoshAdapter(makeSession: { endpoint, dimensions in
            TestTraversioMoshSession(
                endpoint: endpoint,
                dimensions: dimensions,
                snapshot: Self.placeholderSnapshot(dimensions: dimensions)
            )
        })
        _ = try await adapter.connect(
            to: phase9Host(),
            credentials: phase2Credentials(),
            using: bootstrapSession,
            command: "exec herdr terminal attach term_65a1d4135cfa21 --takeover"
        )

        await adapter.leavePaneDaemon(using: bootstrapSession)

        let executed = await bootstrap.executedCommands()
        let killCommand = try XCTUnwrap(executed.last)
        XCTAssertTrue(killCommand.contains("kill -TERM 95522"))
        XCTAssertFalse(killCommand.contains("pkill"))
    }

    func testConnectWaitsForFirstContactWithConfiguredTimeout() async throws {
        let bootstrap = TestMoshBootstrapChannel(
            output: Array(Self.bootstrapOutput.utf8)
        )
        let bootstrapSession = SSHShellSession(connectedChannel: bootstrap)
        let box = MoshSessionBox()
        let adapter = TraversioMoshAdapter(
            makeSession: { endpoint, dimensions in
                let session = TestTraversioMoshSession(
                    endpoint: endpoint,
                    dimensions: dimensions,
                    snapshot: Self.placeholderSnapshot(dimensions: dimensions)
                )
                box.append(session)
                return session
            },
            firstContactTimeout: .milliseconds(250)
        )

        _ = try await adapter.connect(
            to: phase9Host(),
            credentials: phase2Credentials(),
            using: bootstrapSession
        )

        let created = try XCTUnwrap(box.first())
        let timeouts = await created.firstContactTimeoutCalls()
        XCTAssertEqual(
            timeouts,
            [.milliseconds(250)],
            "Connect must gate on a bounded first-contact wait"
        )
    }

    /// A parsed bootstrap line only proves the SSH path works. When the server
    /// never answers over UDP, connect must stop the dead session and surface a
    /// classified timeout so Auto mode keeps SSH.
    func testConnectTimesOutWhenServerNeverContacts() async throws {
        let bootstrap = TestMoshBootstrapChannel(
            output: Array(Self.bootstrapOutput.utf8)
        )
        let bootstrapSession = SSHShellSession(connectedChannel: bootstrap)
        let box = MoshSessionBox()
        let adapter = TraversioMoshAdapter(
            makeSession: { endpoint, dimensions in
                let session = TestTraversioMoshSession(
                    endpoint: endpoint,
                    dimensions: dimensions,
                    snapshot: Self.placeholderSnapshot(dimensions: dimensions),
                    firstContactError: .timedOut
                )
                box.append(session)
                return session
            },
            firstContactTimeout: .milliseconds(50)
        )

        do {
            _ = try await adapter.connect(
                to: phase9Host(),
                credentials: phase2Credentials(),
                using: bootstrapSession
            )
            XCTFail("A dead UDP path must not mount a Mosh session")
        } catch let error as MoshFirstContactError {
            XCTAssertEqual(error, .timedOut)
            XCTAssertEqual(
                TransportSelectionStrategy.classifyMoshFailure(error),
                .udpTimedOut,
                "Auto fallback must classify a first-contact timeout as UDP timeout"
            )
        }

        let created = try XCTUnwrap(box.first())
        let stopped = await created.isStopped()
        XCTAssertTrue(
            stopped,
            "The timed-out session must be stopped, not left mounted"
        )
    }

    /// A blank snapshot for a session double. `MoshTerminalScreen` accepts
    /// dimensions directly, so the fixture needs no throwing initializer and
    /// can be built from the adapter's nonisolated factory closure.
    nonisolated static func placeholderSnapshot(
        dimensions: MoshTerminalDimensions
    ) -> MoshTerminalScreenSnapshot {
        MoshTerminalScreen(dimensions: dimensions).snapshot
    }
}

// MARK: - Test doubles

/// A `MoshTerminalSessionHandling` double that records everything the
/// adapter/channel send it and lets a test publish render operations whose
/// snapshot is read back exactly like `MoshSession.screenSnapshot`.
actor TestTraversioMoshSession: MoshTerminalSessionHandling {
    private let endpoint: MoshEndpoint
    private let dimensions: MoshTerminalDimensions
    private var snapshot: MoshTerminalScreenSnapshot
    private let operations: AsyncThrowingStream<MoshTerminalRenderOperation, Error>
    private let operationsContinuation: AsyncThrowingStream<MoshTerminalRenderOperation, Error>.Continuation
    private var sent: [[UInt8]] = []
    private var resizes: [ResizeCall] = []
    private var started = false
    private var stopped = false
    private var firstContactTimeouts: [Duration] = []
    private let firstContactError: MoshFirstContactError?

    struct ResizeCall: Equatable, Sendable {
        let columns: Int32
        let rows: Int32
    }

    init(
        endpoint: MoshEndpoint,
        dimensions: MoshTerminalDimensions,
        snapshot: MoshTerminalScreenSnapshot,
        firstContactError: MoshFirstContactError? = nil
    ) {
        self.endpoint = endpoint
        self.dimensions = dimensions
        self.snapshot = snapshot
        self.firstContactError = firstContactError
        var continuation: AsyncThrowingStream<MoshTerminalRenderOperation, Error>.Continuation!
        operations = AsyncThrowingStream(bufferingPolicy: .unbounded) {
            continuation = $0
        }
        operationsContinuation = continuation
    }

    func start() async throws {
        started = true
        stopped = false
    }

    func stop() async {
        stopped = true
        operationsContinuation.finish()
    }

    func send(_ bytes: [UInt8]) async throws {
        sent.append(bytes)
    }

    func resize(columns: Int32, rows: Int32) async throws {
        resizes.append(ResizeCall(columns: columns, rows: rows))
    }

    func renderOperations() async -> AsyncThrowingStream<MoshTerminalRenderOperation, Error> {
        operations
    }

    func screenSnapshot() async -> MoshTerminalScreenSnapshot {
        snapshot
    }

    func waitForFirstContact(timeout: Duration) async throws {
        firstContactTimeouts.append(timeout)
        if let firstContactError {
            throw firstContactError
        }
    }

    /// Publishes a render operation after adopting its snapshot, exactly like
    /// the receive path: the stream consumer reads the newest snapshot.
    func publish(
        _ operation: MoshTerminalRenderOperation,
        snapshot: MoshTerminalScreenSnapshot
    ) {
        self.snapshot = snapshot
        operationsContinuation.yield(operation)
    }

    func recordedEndpoint() -> MoshEndpoint { endpoint }
    func recordedDimensions() -> MoshTerminalDimensions { dimensions }
    func sentBytes() -> [[UInt8]] { sent }
    func resizeCalls() -> [ResizeCall] { resizes }
    func firstContactTimeoutCalls() -> [Duration] { firstContactTimeouts }
    func isStarted() -> Bool { started }
    func isStopped() -> Bool { stopped }
}

/// A synchronous box so the adapter's session factory can hand the created
/// double back to the test.
final class MoshSessionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [TestTraversioMoshSession] = []

    func append(_ session: TestTraversioMoshSession) {
        lock.lock()
        defer { lock.unlock() }
        sessions.append(session)
    }

    func first() -> TestTraversioMoshSession? {
        lock.lock()
        defer { lock.unlock() }
        return sessions.first
    }

    func last() -> TestTraversioMoshSession? {
        lock.lock()
        defer { lock.unlock() }
        return sessions.last
    }
}

/// A bootstrap session that records command executions and returns the
/// captured `mosh-server` output.
actor TestMoshBootstrapChannel: PTYChannel, SSHCommandExecutingChannel {
    private let output: [UInt8]
    private var executed: [String] = []

    init(output: [UInt8]) {
        self.output = output
    }

    func execute(_ command: String) async throws -> [UInt8] {
        executed.append(command)
        return output
    }

    func executedCommands() -> [String] {
        executed
    }

    func send(_: [UInt8]) async throws {}
    func resize(columns _: Int, rows _: Int) async throws {}
    func close() async {}
}
