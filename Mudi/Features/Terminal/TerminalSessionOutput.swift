import HerdrKit
import UIKit

/// Session output consumption for ShellTerminalView: pumps bytes from the
/// SSH stream into the terminal grid and reports normal/error closure.
@MainActor
extension ShellTerminalView {
    func consumeOutput(
        of session: SSHShellSession,
        identity: ObjectIdentifier
    ) async {
        let output = await session.outputStream()
        do {
            for try await bytes in output {
                guard isActive(identity) else { return }
                guard !bytes.isEmpty else { continue }
                feed(byteArray: bytes[...])
                logFedFrame(bytes)
            }
            await finishNormally(session, identity: identity)
        } catch {
            guard isActive(identity) else { return }
            await session.disconnect()
            guard isActive(identity) else { return }
            report(error)
        }
    }

    private func finishNormally(
        _ session: SSHShellSession,
        identity: ObjectIdentifier
    ) async {
        guard isActive(identity) else { return }
        didCloseNormally = true
        await session.disconnect()
        guard isActive(identity) else { return }
        onClosed?()
    }

    private func isActive(_ identity: ObjectIdentifier) -> Bool {
        !Task.isCancelled && sessionIdentity == identity
    }

    /// Terminal-side frame diagnostics for the device investigation, gated by
    /// the Settings debug/save-log flags. Repeats the channel's frame hash so
    /// the two log lines correlate, and records the cursor plus inverse-cell
    /// positions SwiftTerm actually holds after the feed — the layer that
    /// separates a wrong snapshot/frame from a display-only artifact.
    func logFedFrame(_ bytes: [UInt8]) {
        let logger = DiagnosticLogger.shared
        guard logger.isDebugLoggingEnabled || logger.isSaveLogsEnabled else { return }
        let terminal = getTerminal()
        var inversePositions: [String] = []
        var cursorRowInverse: [Int] = []
        for row in 0..<terminal.rows {
            guard let line = terminal.getLine(row: row) else { continue }
            for column in 0..<terminal.cols {
                guard line[column].attribute.style.contains(.inverse) else { continue }
                if row == terminal.buffer.y {
                    cursorRowInverse.append(column)
                }
                if inversePositions.count < MoshFrameDiagnostics.maximumInversePositions {
                    inversePositions.append("\(row):\(column)")
                }
            }
        }
        let suspicious = cursorRowInverse.count > 1
        let hash = MoshFrameDiagnostics.hash(bytes)
        let cursor = "\(terminal.buffer.y):\(terminal.buffer.x)"
        let line = "hash=\(hash) bytes=\(bytes.count) cursor=\(cursor) "
            + "cursorRowInv=[\(cursorRowInverse.map(String.init).joined(separator: ","))] "
            + "inv=[\(inversePositions.joined(separator: ","))]"
        logger.log(
            level: suspicious ? .error : .debug,
            category: "mosh-term",
            line
        )
    }
}
