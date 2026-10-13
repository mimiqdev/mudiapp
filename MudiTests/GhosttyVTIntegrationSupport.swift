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

/// A real UIKit hardware key object for production `pressesBegan` dispatch.
/// UIKit has no public UIKey initializer with values; only these read-only
/// properties are overridden, the view's UIKit responder path is unchanged.
final class GhosttyVTTestKey: UIKey {
    private let code: UIKeyboardHIDUsage
    private let flags: UIKeyModifierFlags
    private let ignoring: String
    private let typed: String
    init(_ code: UIKeyboardHIDUsage, _ flags: UIKeyModifierFlags = [], ignoring: String = "", typed: String? = nil) {
        self.code = code
        self.flags = flags
        self.ignoring = ignoring
        self.typed = typed ?? ignoring
        super.init()
    }
    required init?(coder: NSCoder) { nil }
    override var keyCode: UIKeyboardHIDUsage { code }
    override var modifierFlags: UIKeyModifierFlags { flags }
    override var charactersIgnoringModifiers: String { ignoring }
    override var characters: String { typed }
}

final class GhosttyVTTestPress: UIPress {
    private let testKey: UIKey
    init(_ key: UIKey) { testKey = key; super.init() }
    override var key: UIKey? { testKey }
}

/// Next responder: records presses the terminal forwarded to `super`, i.e.
/// what UIKit's text system (insertText/deleteBackward) would still receive.
final class GhosttyVTPressRecorder: UIView {
    var forwarded: [UIKeyboardHIDUsage] = []
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        forwarded += presses.compactMap { $0.key?.keyCode }
    }
}

@MainActor
func ghosttyPress(_ view: UIView, _ key: UIKey, release: Bool = true) {
    let press = GhosttyVTTestPress(key)
    view.pressesBegan([press], with: nil)
    if release { view.pressesEnded([press], with: nil) }
}

@MainActor
func ghosttyWait(_ observation: () async -> Bool) async -> Bool {
    for _ in 0..<200 {
        if await observation() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await observation()
}
