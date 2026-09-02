import Foundation
import HerdrKit
import XCTest
@testable import Mudi

@MainActor
final class Phase6TakeoverSizeTests: XCTestCase {
    func testTakeoverFallsBackToDefaultSizeBeforeAnyResizeIsRecorded() async {
        let size = await makeTransportSize(recording: nil)
        XCTAssertEqual(size, HerdrTerminalSize(columns: 80, rows: 24))

        let inner = SSHHerdrTerminalTransport.takeoverInnerCommand(
            target: "'w55:t1.0'",
            sessionOption: "",
            size: size
        )
        XCTAssertTrue(inner.contains("--takeover --cols 80 --rows 24"))
    }

    func testTakeoverUsesRecordedTerminalSizeToAvoidRemoteRelayout() async {
        let size = await makeTransportSize(
            recording: HerdrTerminalSize(columns: 118, rows: 41)
        )
        XCTAssertEqual(size, HerdrTerminalSize(columns: 118, rows: 41))

        let inner = SSHHerdrTerminalTransport.takeoverInnerCommand(
            target: "'w55:t1.0'",
            sessionOption: "",
            size: size
        )
        XCTAssertTrue(inner.contains("--takeover --cols 118 --rows 41"))
    }

    func testControlChannelSkipsResizeMatchingTheTakeoverSize() async throws {
        let underlying = TakeoverSizeCapturingChannel()
        let channel = HerdrControlChannel(
            underlying: underlying,
            initialSize: HerdrTerminalSize(columns: 118, rows: 41)
        )
        await channel.start()
        let observer = TakeoverSizeObserver()
        await channel.setResizeObserver { columns, rows in
            observer.record(HerdrTerminalSize(columns: columns, rows: rows))
        }

        // Same size as the takeover: no SIGWINCH-triggering frame is sent.
        try await channel.resize(columns: 118, rows: 41)
        var sentCount = await underlying.sentCount()
        XCTAssertEqual(sentCount, 0)
        XCTAssertEqual(observer.values(), [])

        // A real geometry change is forwarded and recorded once.
        try await channel.resize(columns: 100, rows: 30)
        try await channel.resize(columns: 100, rows: 30)
        sentCount = await underlying.sentCount()
        XCTAssertEqual(sentCount, 1)
        XCTAssertEqual(
            observer.values(),
            [HerdrTerminalSize(columns: 100, rows: 30)]
        )
        let sentBytes = await underlying.firstSentBytes()
        let sentText = String(decoding: sentBytes ?? [], as: UTF8.self)
        XCTAssertTrue(sentText.contains("\"terminal.resize\""))
        XCTAssertTrue(sentText.contains("\"cols\":100"))
        XCTAssertTrue(sentText.contains("\"rows\":30"))

        await channel.close()
    }

    private func makeTransportSize(
        recording size: HerdrTerminalSize?
    ) async -> HerdrTerminalSize {
        let session = SSHShellSession(
            connectedChannel: TakeoverSizeCapturingChannel()
        )
        let transport = SSHHerdrTerminalTransport(session: session)
        if let size {
            await transport.recordTerminalSize(
                columns: size.columns,
                rows: size.rows
            )
        }
        return await transport.currentTakeoverSize
    }
}

private final class TakeoverSizeObserver: @unchecked Sendable {
    private var recorded: [HerdrTerminalSize] = []
    private let lock = NSLock()

    func record(_ size: HerdrTerminalSize) {
        lock.lock()
        recorded.append(size)
        lock.unlock()
    }

    func values() -> [HerdrTerminalSize] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

private actor TakeoverSizeCapturingChannel: PTYOutputChannel {
    private var sent: [[UInt8]] = []
    private var continuation: AsyncThrowingStream<[UInt8], Error>.Continuation?

    func outputStream() async -> AsyncThrowingStream<[UInt8], Error> {
        AsyncThrowingStream { continuation in
            self.continuation = continuation
        }
    }

    func send(_ bytes: [UInt8]) async throws {
        sent.append(bytes)
    }

    func resize(columns _: Int, rows _: Int) async throws {}

    func close() async {
        continuation?.finish()
        continuation = nil
    }

    func sentCount() -> Int {
        sent.count
    }

    func firstSentBytes() -> [UInt8]? {
        sent.first
    }
}
