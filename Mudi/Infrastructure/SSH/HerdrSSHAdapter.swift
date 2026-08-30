import Foundation
import HerdrKit

/// Discovers Herdr through the already-authenticated interactive shell.
///
/// The command is framed with private markers so the shell prompt and command
/// echo are not mistaken for JSON. If the Herdr executable is absent, the
/// framed payload is empty and discovery reports no active sessions.
actor SSHHerdrDiscovery: HerdrDiscovering {
    private let session: SSHShellSession

    init(session: SSHShellSession) {
        self.session = session
    }

    func snapshot(for _: Host) async throws -> HerdrSnapshot {
        let marker = "MUDI_HERDR_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let begin = Array("\u{1e}\(marker)_BEGIN\u{1e}".utf8)
        let end = Array("\u{1e}\(marker)_END\u{1e}".utf8)
        let command = "printf '\\036%s_BEGIN\\036\\n' '\(marker)'; "
            + "if command -v herdr >/dev/null 2>&1; then herdr session list --json; fi; "
            + "printf '\\036%s_END\\036\\n' '\(marker)'\n"

        let output = await session.outputStream()
        try await session.send(Array(command.utf8))
        let payload = try await readPayload(
            from: output,
            begin: begin,
            end: end
        )
        return try decodeSnapshot(from: payload)
    }

    private func readPayload(
        from output: AsyncThrowingStream<[UInt8], Error>,
        begin: [UInt8],
        end: [UInt8]
    ) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await Self.collectPayload(
                    from: output,
                    begin: begin,
                    end: end
                )
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 10_000_000_000)
                throw SSHHerdrDiscoveryError.timedOut
            }
            defer { group.cancelAll() }
            guard let payload = try await group.next() else {
                throw SSHHerdrDiscoveryError.noResponse
            }
            return payload
        }
    }

    private static func collectPayload(
        from output: AsyncThrowingStream<[UInt8], Error>,
        begin: [UInt8],
        end: [UInt8]
    ) async throws -> Data {
        var bytes: [UInt8] = []
        for try await chunk in output {
            guard !Task.isCancelled else {
                throw CancellationError()
            }
            bytes.append(contentsOf: chunk)
            guard let endRange = firstRange(of: end, in: bytes) else {
                continue
            }
            guard let beginRange = lastRange(
                of: begin,
                in: bytes,
                before: endRange.lowerBound
            ) else {
                throw SSHHerdrDiscoveryError.invalidResponse
            }
            return Data(bytes[beginRange.upperBound..<endRange.lowerBound])
        }
        throw SSHHerdrDiscoveryError.noResponse
    }

    private func decodeSnapshot(from data: Data) throws -> HerdrSnapshot {
        let cleanedData = Self.removeTerminalEscapes(from: data)
        guard let response = String(data: cleanedData, encoding: .utf8) else {
            throw SSHHerdrDiscoveryError.invalidResponse
        }
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return HerdrSnapshot(sessions: [])
        }

        let decoder = JSONDecoder()
        if let snapshot = try? decoder.decode(HerdrSnapshot.self, from: Data(trimmed.utf8)) {
            return snapshot
        }
        if let sessions = try? decoder.decode([HerdrSession].self, from: Data(trimmed.utf8)) {
            return HerdrSnapshot(sessions: sessions)
        }
        throw SSHHerdrDiscoveryError.invalidJSON
    }

    private static func firstRange(of needle: [UInt8], in haystack: [UInt8]) -> Range<Int>? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        let lastStart = haystack.count - needle.count
        for start in 0...lastStart where haystack[start..<start + needle.count].elementsEqual(needle) {
            return start..<(start + needle.count)
        }
        return nil
    }

    private static func lastRange(
        of needle: [UInt8],
        in haystack: [UInt8],
        before limit: Int
    ) -> Range<Int>? {
        guard !needle.isEmpty, limit >= needle.count else { return nil }
        var result: Range<Int>?
        let lastStart = limit - needle.count
        for start in 0...lastStart where haystack[start..<start + needle.count].elementsEqual(needle) {
            result = start..<(start + needle.count)
        }
        return result
    }

    private static func removeTerminalEscapes(from data: Data) -> Data {
        var result: [UInt8] = []
        var skippingEscape = false
        for byte in data {
            if skippingEscape {
                if (0x40...0x7e).contains(byte) {
                    skippingEscape = false
                }
                continue
            }
            if byte == 0x1b {
                skippingEscape = true
                continue
            }
            result.append(byte)
        }
        return Data(result)
    }
}

enum SSHHerdrDiscoveryError: Error, LocalizedError, Sendable {
    case timedOut
    case noResponse
    case invalidResponse
    case invalidJSON

    var errorDescription: String? {
        switch self {
        case .timedOut:
            "Herdr discovery timed out."
        case .noResponse, .invalidResponse, .invalidJSON:
            "Herdr discovery returned an invalid response."
        }
    }
}

/// Adapts the existing SSH PTY to the phase-3 terminal transport boundary.
///
/// A host has already been connected before this adapter is created, so
/// `connect(to:)` is intentionally a no-op. Selecting a pane sends Herdr's
/// control command through the same interactive channel that SwiftTerm reads.
actor SSHHerdrTerminalTransport: TerminalTransport {
    nonisolated let kind: ActiveTransport = .ssh
    private let session: SSHShellSession

    init(session: SSHShellSession) {
        self.session = session
    }

    func connect(to _: Host) async throws {}

    func attach(to pane: Pane) async throws {
        let target = Self.shellQuote(pane.id)
        let command = "herdr terminal session control \(target) --cols 80 --rows 24\n"
        try await session.send(Array(command.utf8))
    }

    func send(_ bytes: [UInt8]) async throws {
        try await session.send(bytes)
    }

    func resize(columns: Int, rows: Int) async throws {
        try await session.resize(columns: columns, rows: rows)
    }

    func disconnect() async {
        await session.disconnect()
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
