import Foundation
import HerdrKit
import TraversioMoshCore

/// Presents a Traversio Mosh session through the terminal PTY boundary.
///
/// SwiftTerm eats bytes, while Traversio owns the framebuffer as structured
/// snapshots. The channel therefore forwards *complete replacement frames*
/// rendered from `screenSnapshot`, not incremental diffs: every render
/// operation triggers one ``MoshScreenFrameRenderer`` frame. The output
/// stream keeps only the newest pending display frame; because each frame
/// replaces the previous one wholesale, dropping an intermediate frame is
/// lossless for the displayed picture. Bell/title control bytes are retained
/// across an evicted frame and re-attached to the next delivered frame, so a
/// dropped frame can never swallow those signals permanently.
actor MoshPTYChannel: PTYOutputChannel {
    private let session: any MoshTerminalSessionHandling
    private let output: AsyncThrowingStream<[UInt8], Error>
    private let outputContinuation: AsyncThrowingStream<[UInt8], Error>.Continuation
    private var pumpTask: Task<Void, Never>?
    private var isClosed = false
    /// Owns the cross-frame signals (bell count, title changes) so each frame
    /// stays a self-contained replacement while deltas between frames still
    /// reach SwiftTerm.
    private var frameRenderer = MoshScreenFrameRenderer()
    /// Monotonic frame counter for the diagnostic log (only advanced when
    /// frame diagnostics are emitted).
    private var frameSequence: UInt64 = 0
    private let logger: DiagnosticLogger
    /// Control bytes from a frame that was yielded but not yet confirmed
    /// consumed. Re-attached to the next frame so an eviction cannot drop a
    /// bell or title permanently.
    private var retainedControlBytes: [UInt8] = []

    init(
        session: any MoshTerminalSessionHandling,
        logger: DiagnosticLogger = .shared
    ) {
        self.session = session
        self.logger = logger
        var continuation: AsyncThrowingStream<[UInt8], Error>.Continuation!
        output = AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) {
            continuation = $0
        }
        outputContinuation = continuation
    }

    func outputStream() async -> AsyncThrowingStream<[UInt8], Error> {
        startPump()
        return output
    }

    func send(_ bytes: [UInt8]) async throws {
        guard !isClosed else { throw MoshSessionChannelError.closed }
        guard !bytes.isEmpty else { return }
        try await session.send(bytes)
    }

    func resize(columns: Int, rows: Int) async throws {
        guard !isClosed else { throw MoshSessionChannelError.closed }
        guard columns > 0, rows > 0 else { return }
        guard let columns = Int32(exactly: columns),
              let rows = Int32(exactly: rows)
        else {
            throw MoshSessionChannelError.invalidSize
        }
        try await session.resize(columns: columns, rows: rows)
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        pumpTask?.cancel()
        pumpTask = nil
        outputContinuation.finish()
        await session.stop()
    }

    /// Consumes Traversio's render stream and re-renders the newest
    /// `screenSnapshot` for every delivered operation. The snapshot, not the
    /// operation payload, is the display source: the operation only marks
    /// that the authoritative frame changed.
    private func startPump() {
        guard pumpTask == nil, !isClosed else { return }
        self.logger.log(
            level: .notice,
            category: "mosh-frame",
            "frame diagnostics started (enable Settings > Diagnostics > Save Logs to persist)"
        )
        let session = self.session
        pumpTask = Task { [weak self] in
            let operations = await session.renderOperations()
            do {
                for try await _ in operations {
                    guard !Task.isCancelled else { return }
                    let snapshot = await session.screenSnapshot()
                    let frame = await self?.render(snapshot)
                    guard let frame, !Task.isCancelled else { return }
                    await self?.yield(frame, snapshot: snapshot)
                }
                await self?.finish(throwing: nil)
            } catch {
                await self?.finish(throwing: error)
            }
        }
    }

    private func render(_ snapshot: MoshTerminalScreenSnapshot) -> MoshScreenFrame? {
        guard !isClosed else { return nil }
        return frameRenderer.render(snapshot)
    }

    /// Yields one frame, carrying any control bytes from a previously yielded
    /// frame that has not been confirmed consumed. `AsyncThrowingStream`'s
    /// `.bufferingNewest(1)` reports the fate of the previous element: an
    /// evicted one is returned by `.dropped`, and a buffered one is
    /// `.enqueued(remaining: > 0)`. Until an element is delivered to a waiting
    /// consumer (`remaining == 0`), its control bytes stay retained and are
    /// re-attached to the next frame — at-least-once delivery for bells and
    /// titles, while display frames remain latest-only.
    private func yield(_ frame: MoshScreenFrame, snapshot: MoshTerminalScreenSnapshot) {
        guard !isClosed else { return }
        let controlBytes = retainedControlBytes + frame.controlBytes
        var bytes = controlBytes
        bytes.append(contentsOf: frame.frameBytes)
        let result = outputContinuation.yield(bytes)
        let outcome: String
        switch result {
        case let .enqueued(remaining):
            retainedControlBytes = remaining > 0 ? controlBytes : []
            outcome = "enqueued(\(remaining))"
        case .dropped:
            retainedControlBytes = controlBytes
            outcome = "dropped"
        case .terminated:
            outcome = "terminated"
        @unknown default:
            // An unknown future result cannot prove delivery, so keep the
            // control bytes pending for the next frame.
            retainedControlBytes = controlBytes
            outcome = "unknown"
        }
        self.logFrame(snapshot: snapshot, bytes: bytes, outcome: outcome)
    }

    /// Frame-level diagnostics for the device investigation, gated by the
    /// Settings debug/save-log flags so normal runs pay nothing. The line
    /// carries the painted snapshot's cursor and inverse-cell positions plus
    /// the frame hash the terminal-side log repeats.
    private func logFrame(
        snapshot: MoshTerminalScreenSnapshot,
        bytes: [UInt8],
        outcome: String
    ) {
        self.frameSequence &+= 1
        let sequence = self.frameSequence
        let logger = self.logger
        guard logger.isDebugLoggingEnabled || logger.isSaveLogsEnabled else { return }
        let state = MoshFrameDiagnostics.state(of: snapshot)
        let retained = self.retainedControlBytes.count
        let line = MoshFrameDiagnostics.line(
            sequence: sequence,
            state: state,
            snapshot: snapshot,
            bytes: bytes,
            retainedControlByteCount: retained,
            outcome: outcome
        )
        logger.log(
            level: state.isSuspicious ? .error : .debug,
            category: "mosh-frame",
            line
        )
    }

    private func finish(throwing error: Error?) {
        guard !isClosed else { return }
        isClosed = true
        pumpTask = nil
        outputContinuation.finish(throwing: error)
    }
}

enum MoshSessionChannelError: Error, LocalizedError, Equatable, Sendable {
    case closed
    case invalidSize

    var errorDescription: String? {
        switch self {
        case .closed:
            "The Mosh terminal connection is closed."
        case .invalidSize:
            "The Mosh terminal size is invalid."
        }
    }
}
