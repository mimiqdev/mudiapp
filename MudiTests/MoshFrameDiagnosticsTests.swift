import Foundation
import TraversioMoshBootstrap
import TraversioMoshCore
import XCTest
@testable import Mudi

@MainActor
final class MoshFrameDiagnosticsTests: XCTestCase {
    func testHashIsStableAndDistinguishesFrames() {
        let hash = MoshFrameDiagnostics.hash([1, 2, 3])
        XCTAssertEqual(hash, MoshFrameDiagnostics.hash([1, 2, 3]))
        XCTAssertNotEqual(hash, MoshFrameDiagnostics.hash([1, 2, 4]))
        XCTAssertNotEqual(hash, MoshFrameDiagnostics.hash([1, 2, 3, 0]))
        XCTAssertFalse(hash.isEmpty)
    }

    func testRawLineCarriesHashAndBoundedHex() {
        let line = MoshFrameDiagnostics.rawLine(
            sequence: 3,
            bytes: [0x1b, 0x5b, 0x32, 0x4b]
        )
        XCTAssertTrue(line.contains("seq=3"))
        XCTAssertTrue(line.contains("bytes=4"))
        XCTAssertTrue(line.contains("hex=1b5b324b"))

        let long = MoshFrameDiagnostics.rawLine(
            sequence: 4,
            bytes: Array(repeating: 0x41, count: 200)
        )
        XCTAssertTrue(long.contains("bytes=200"))
        XCTAssertTrue(long.hasSuffix("...+72"), long)
    }

    func testStateFindsInverseCellsAndFlagsMultipleCursorBlocks() throws {
        var screen = MoshTerminalScreen(
            dimensions: try MoshTerminalDimensions(columns: 20, rows: 4)
        )
        _ = try screen.apply(MoshTerminalOutput(bytes: Array("gui好像天然".utf8)))
        _ = try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[7m \u{1b}[0m".utf8)))
        _ = try screen.apply(
            MoshTerminalOutput(bytes: Array("\u{1b}[15G\u{1b}[7m \u{1b}[0m".utf8))
        )
        let snapshot = screen.snapshot

        let state = MoshFrameDiagnostics.state(of: snapshot)

        XCTAssertEqual(state.cursorRowInverse, [11, 14])
        XCTAssertEqual(state.inversePositions, ["0:11", "0:14"])
        XCTAssertTrue(state.isSuspicious)
        XCTAssertTrue(state.rowText.hasPrefix("gui好像天然"))
    }

    func testStateWithSingleCursorIsNotSuspicious() throws {
        var screen = MoshTerminalScreen(
            dimensions: try MoshTerminalDimensions(columns: 20, rows: 4)
        )
        _ = try screen.apply(MoshTerminalOutput(bytes: Array("gui好像天然".utf8)))
        _ = try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[7m \u{1b}[0m".utf8)))
        let snapshot = screen.snapshot

        let state = MoshFrameDiagnostics.state(of: snapshot)

        XCTAssertEqual(state.cursorRowInverse, [11])
        XCTAssertFalse(state.isSuspicious)
        let line = MoshFrameDiagnostics.line(
            sequence: 7,
            state: state,
            snapshot: snapshot,
            bytes: [1, 2, 3],
            retainedControlByteCount: 0,
            outcome: "enqueued(1)"
        )
        XCTAssertTrue(line.contains("seq=7"))
        XCTAssertTrue(line.contains("cursor=0:12"))
        XCTAssertTrue(line.contains("cursorRowInv=[11]"))
        XCTAssertTrue(line.contains("hash="))
        XCTAssertTrue(line.contains("outcome=enqueued(1)"))
    }

    /// The channel must emit the frame line through its logger so the device
    /// log carries the painted snapshot state and the frame hash.
    func testChannelWritesFrameDiagnosticsToInjectedLog() async throws {
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mosh-frame-\(UUID().uuidString).log")
        let writer = DiagnosticFileWriter(logFileURL: logURL)
        let logger = DiagnosticLogger(fileWriter: writer)
        logger.configure(isDebugLoggingEnabled: true, isSaveLogsEnabled: true)
        defer { try? FileManager.default.removeItem(at: logURL) }

        var screen = MoshTerminalScreen(
            dimensions: try MoshTerminalDimensions(columns: 20, rows: 4)
        )
        _ = try screen.apply(MoshTerminalOutput(bytes: Array("gui好像天然".utf8)))
        _ = try screen.apply(MoshTerminalOutput(bytes: Array("\u{1b}[7m \u{1b}[0m".utf8)))
        let withCursor = screen.snapshot
        _ = try screen.apply(
            MoshTerminalOutput(bytes: Array("\u{1b}[15G\u{1b}[7m \u{1b}[0m".utf8))
        )
        let suspicious = screen.snapshot

        let bootstrap = try MoshBootstrapParser.parse(
            "MOSH CONNECT 60001 GE0sKFO189zPL+rA0/xACg"
        )
        let session = TestTraversioMoshSession(
            endpoint: MoshEndpoint(
                host: "127.0.0.1",
                port: bootstrap.port,
                sessionKey: bootstrap.sessionKey
            ),
            dimensions: try MoshTerminalDimensions(columns: 20, rows: 4),
            snapshot: withCursor
        )
        let channel = MoshPTYChannel(session: session, logger: logger)
        let stream = await channel.outputStream()
        var iterator = stream.makeAsyncIterator()

        await session.publish(
            .write(MoshTerminalOutput(bytes: Array("x".utf8))),
            snapshot: withCursor
        )
        _ = try await iterator.next()
        await session.publish(
            .write(MoshTerminalOutput(bytes: Array("y".utf8))),
            snapshot: suspicious
        )
        _ = try await iterator.next()

        let contents = try await waitForLog(
            logURL,
            containing: "cursorRowInv=[11,14]"
        )
        XCTAssertTrue(contents.contains("[mosh-frame]"))
        XCTAssertTrue(
            contents.contains("[error]"),
            "Multiple cursor blocks must be logged at error level: \(contents)"
        )
        await channel.close()
    }

    private func waitForLog(
        _ url: URL,
        containing needle: String
    ) async throws -> String {
        for _ in 0..<50 {
            if let data = try? Data(contentsOf: url),
               let text = String(data: data, encoding: .utf8),
               text.contains(needle) {
                return text
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let text = (try? Data(contentsOf: url))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        XCTFail("log did not contain \(needle): \(text)")
        return text
    }
}
