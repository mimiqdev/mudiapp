import Foundation
import TraversioMoshCore

/// Compact, bounded diagnostics for the Mosh frame pipeline.
///
/// The device investigation needs to answer one question at the moment of
/// corruption: did the painted snapshot already contain the wrong cells, did
/// the rendered frame bytes change them, or did SwiftTerm's buffer diverge?
/// These helpers keep the per-frame log line small enough for the rolling
/// debug log while still carrying the cursor, the positions of inverse
/// (reverse-video) cells, the cursor row's text, and a frame hash that the
/// terminal-side log repeats for correlation.
enum MoshFrameDiagnostics {
    static let maximumInversePositions = 16
    static let maximumRowTextScalars = 64

    struct FrameState {
        /// Columns of inverse cells on the cursor row; more than one is the
        /// screenshot's corruption signature (a single software cursor block
        /// is expected).
        let cursorRowInverse: [Int]
        /// Bounded "row:column" list of inverse cells across the whole frame.
        let inversePositions: [String]
        let rowText: String

        var isSuspicious: Bool {
            self.cursorRowInverse.count > 1
        }
    }

    static func state(of snapshot: MoshTerminalScreenSnapshot) -> FrameState {
        var inversePositions: [String] = []
        for (rowIndex, row) in snapshot.rows.enumerated() {
            for (column, cell) in row.enumerated() where cell.attributes.isInverse {
                if inversePositions.count < Self.maximumInversePositions {
                    inversePositions.append("\(rowIndex):\(column)")
                }
            }
        }

        let cursorRow: [MoshTerminalCell] = snapshot.rows.indices.contains(snapshot.cursor.row)
            ? snapshot.rows[snapshot.cursor.row]
            : []
        let cursorRowInverse = cursorRow.enumerated().compactMap { column, cell in
            cell.attributes.isInverse ? column : nil
        }
        let rowText = cursorRow.filter { !$0.isContinuation }.map(\.contents).joined()
            .replacingOccurrences(of: " ", with: "·")

        return FrameState(
            cursorRowInverse: cursorRowInverse,
            inversePositions: inversePositions,
            rowText: String(rowText.prefix(Self.maximumRowTextScalars))
        )
    }

    static func line(
        sequence: UInt64,
        state: FrameState,
        snapshot: MoshTerminalScreenSnapshot,
        bytes: [UInt8],
        retainedControlByteCount: Int,
        outcome: String
    ) -> String {
        "seq=\(sequence) cursor=\(snapshot.cursor.row):\(snapshot.cursor.column) "
            + "vis=\(snapshot.isCursorVisible) "
            + "dims=\(snapshot.dimensions.columns)x\(snapshot.dimensions.rows) "
            + "cursorRowInv=[\(state.cursorRowInverse.map(String.init).joined(separator: ","))] "
            + "inv=[\(state.inversePositions.joined(separator: ","))] "
            + "row=\"\(state.rowText)\" bytes=\(bytes.count) hash=\(hash(bytes)) "
            + "retained=\(retainedControlByteCount) outcome=\(outcome)"
    }

    /// FNV-1a, chosen for being tiny and dependency-free; the value only needs
    /// to correlate the channel's frame with the terminal's post-feed buffer.
    static func hash(_ bytes: [UInt8]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    static let maximumRawHexBytes = 128

    /// One raw host operation (post-decryption terminal output) with a bounded
    /// hex prefix. Correlating this with the `mosh-frame` snapshot line and the
    /// `mosh-term` buffer line localizes snapshot/engine corruption against an
    /// already-wrong wire stream.
    static func rawLine(sequence: UInt64, bytes: [UInt8]) -> String {
        let prefix = bytes.prefix(Self.maximumRawHexBytes)
        let hex = prefix.map { String(format: "%02x", $0) }.joined()
        let truncated = bytes.count > Self.maximumRawHexBytes
            ? "...+\(bytes.count - Self.maximumRawHexBytes)"
            : ""
        return "seq=\(sequence) bytes=\(bytes.count) hash=\(hash(bytes)) hex=\(hex)\(truncated)"
    }
}
