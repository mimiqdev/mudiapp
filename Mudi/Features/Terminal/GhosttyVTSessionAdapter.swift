import Foundation
import GhosttyVt
import HerdrKit

/// One consumer of an already-connected session. This is a renderer adapter,
/// never a connection factory. Hiding/removing the surface must leave this
/// adapter running so output continues to reach VT without a pre-attach queue.
@MainActor
final class GhosttyVTSessionAdapter {
    enum AdapterError: Error { case notStarted }

    let view: GhosttyVTView
    let session: SSHShellSession
    var onError: ((Error) -> Void)?
    var onClosed: (() -> Void)?
    var onBell: (() -> Void)?
    var onTitleChange: ((String) -> Void)?
    var onWorkingDirectoryChange: ((String?) -> Void)?
    private var outputTask: Task<Void, Never>?
    private var outboundTask: Task<Void, Error>?
    private var generation = 0
    private var isRunning = false
    private var lastSentSize: GhosttyVt.Terminal.Size?

    private enum Operation {
        case write([Data])
        case resize(GhosttyVt.Terminal.Size)
    }

    init(view: GhosttyVTView, session: SSHShellSession) {
        self.view = view
        self.session = session
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        generation += 1
        let identity = generation
        lastSentSize = nil
        view.onGridResize = { [weak self] in self?.resizePTY(to: $0) }
        view.onRenderError = { [weak self] in self?.onError?($0) }
        // The host may already have laid out this view before binding the PTY.
        // In that case no new grid-change callback occurs: sync it once here.
        view.setNeedsLayout()
        view.layoutIfNeeded()
        if GhosttyVTGridGeometry.size(viewport: view.bounds.size, cell: view.cellSize) != nil {
            resizePTY(to: view.screen.size)
        }
        outputTask = Task { [weak self] in
            await self?.consumeOutput(identity: identity)
        }
    }

    /// Detaches rendering, not the connection. EOF/error handling below owns
    /// the same explicit disconnect semantics as ShellTerminalView's pump.
    /// This must not be used merely because a view became hidden/off-window.
    func stop() {
        isRunning = false
        generation += 1
        outputTask?.cancel()
        outputTask = nil
        outboundTask?.cancel()
        outboundTask = nil
        lastSentSize = nil
        view.onGridResize = nil
        view.onRenderError = nil
    }

    func sendKey(_ event: GhosttyVt.Terminal.KeyEvent) async throws {
        guard isRunning else { throw AdapterError.notStarted }
        try await sendInput([try view.terminal.encode(event)])
    }

    /// The UIKit input adapter must call this ONLY after a composition commits;
    /// VT is an encoder, not a UITextInput implementation.
    func sendCommittedText(_ text: String) async throws {
        guard !text.isEmpty else { return }
        try await sendKey(.init(text: text))
    }

    func paste(_ text: String, appendEnter: Bool = false) async throws {
        guard isRunning else { throw AdapterError.notStarted }
        var data = [try view.terminal.encodePaste(text)]
        if appendEnter { data.append(try view.terminal.encode(.init(key: .enter))) }
        // Paste and its explicit Enter are a single ordered batch, not two
        // unstructured Tasks that can interleave with a VT query response.
        try await sendInput(data)
    }

    private func sendInput(_ data: [Data]) async throws {
        do {
            try await enqueue(.write(data)).value
        } catch let error as ReportedWriteError {
            // The wrapper is only an internal duplicate-report marker for
            // the output pump; explicit input callers get the real PTY error.
            throw error.underlying
        }
    }

    private func consumeOutput(identity: Int) async {
        let output = await session.outputStream()
        do {
            for try await bytes in output {
                guard isCurrent(identity), !Task.isCancelled else { return }
                guard !bytes.isEmpty else { continue }
                // Feed every byte even with no window. The bounded VT
                // scrollback is the retained state, not a lossy raw queue.
                let events = try view.feed(Data(bytes))
                for event in events {
                    // A completed in-flight write may ignore cancellation.
                    // Recheck before publishing any remaining old-session UI
                    // effects; a guard only before the whole frame isn't enough.
                    guard isCurrent(identity), !Task.isCancelled else { return }
                    switch event {
                    case .writeToPty(let reply):
                        try await enqueue(.write([reply])).value
                    case .bell: onBell?()
                    case .titleChanged(let title): onTitleChange?(title)
                    case .workingDirectoryChanged(let directory): onWorkingDirectoryChange?(directory)
                    }
                }
            }
            guard isCurrent(identity), !Task.isCancelled else { return }
            await session.disconnect()
            guard isCurrent(identity), !Task.isCancelled else { return }
            isRunning = false
            onClosed?()
        } catch {
            guard isCurrent(identity), !Task.isCancelled else { return }
            await session.disconnect()
            guard isCurrent(identity), !Task.isCancelled else { return }
            isRunning = false
            // Outbound errors are reported at the operation itself, so don't
            // report the same writeToPty failure twice through the output pump.
            if !(error is ReportedWriteError) { onError?(error) }
        }
    }

    private func resizePTY(to size: GhosttyVt.Terminal.Size) {
        guard isRunning, size.columns > 0, size.rows > 0, lastSentSize != size else { return }
        lastSentSize = size
        _ = enqueue(.resize(size))
    }

    /// Tail-chained operations preserve ordering across asynchronous PTY calls
    /// (actor reentrancy alone doesn't). Every error is both observable via
    /// callback and throwable to an explicit input caller.
    private func enqueue(_ operation: Operation) -> Task<Void, Error> {
        let previous = outboundTask
        let identity = generation
        let session = session
        let task = Task { [weak self] in
            _ = try? await previous?.value
            guard let self, self.isCurrent(identity), !Task.isCancelled else {
                throw CancellationError()
            }
            do {
                switch operation {
                case .write(let batch):
                    for data in batch where !data.isEmpty {
                        guard self.isCurrent(identity), !Task.isCancelled else { throw CancellationError() }
                        try await session.send(Array(data))
                    }
                case .resize(let size):
                    try await session.resize(columns: Int(size.columns), rows: Int(size.rows))
                }
            } catch {
                guard self.isCurrent(identity), !Task.isCancelled else { throw CancellationError() }
                self.onError?(error)
                throw ReportedWriteError(underlying: error)
            }
        }
        outboundTask = task
        return task
    }

    private func isCurrent(_ identity: Int) -> Bool {
        isRunning && generation == identity
    }

    private struct ReportedWriteError: Error {
        let underlying: Error
    }
}
