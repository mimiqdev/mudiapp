import Foundation
import GhosttyVt
import HerdrKit
import UIKit
import XCTest
@testable import Mudi

actor GhosttyVTTestPTY: PTYOutputChannel {
    struct Snapshot: Sendable {
        var sent: [[UInt8]]
        var sizes: [GhosttyVt.Terminal.Size]
        var readers: Int
        var closes: Int
    }
    private let stream: AsyncThrowingStream<[UInt8], Error>
    private let continuation: AsyncThrowingStream<[UInt8], Error>.Continuation
    private var state = Snapshot(sent: [], sizes: [], readers: 0, closes: 0)
    init() { (stream, continuation) = AsyncThrowingStream.makeStream() }
    func outputStream() -> AsyncThrowingStream<[UInt8], Error> { state.readers += 1; return stream }
    func send(_ bytes: [UInt8]) { state.sent.append(bytes) }
    func resize(columns: Int, rows: Int) { state.sizes.append(.init(columns: UInt16(columns), rows: UInt16(rows))) }
    func close() { state.closes += 1; continuation.finish() }
    func emit(_ text: String) { continuation.yield(Array(text.utf8)) }
    func finish() { continuation.finish() }
    func snapshot() -> Snapshot { state }
}

@MainActor
func ghosttyWait(_ observation: () async -> Bool) async -> Bool {
    for _ in 0..<200 {
        if await observation() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await observation()
}
