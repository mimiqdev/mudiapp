import Foundation
import OSLog

public enum DiagnosticLogging {
    public static let relativeLogPath = "Documents/mudi-debug.log"

    public static var logFileURL: URL {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsURL.appendingPathComponent("mudi-debug.log")
    }

    public static var rotatedLogFileURL: URL {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsURL.appendingPathComponent("mudi-debug.1.log")
    }
}

public enum DiagnosticLogLevel: String, Sendable {
    case notice
    case debug
    case error
}

public final class DiagnosticLogger: @unchecked Sendable {
    public static let shared = DiagnosticLogger()

    private let lock = NSLock()
    private var _isDebugLoggingEnabled = false
    private var _isSaveLogsEnabled = false

    private let fileWriter: DiagnosticFileWriter
    private let isoFormatter: ISO8601DateFormatter

    public init(
        fileWriter: DiagnosticFileWriter = DiagnosticFileWriter(
            logFileURL: DiagnosticLogging.logFileURL,
            rotatedLogFileURL: DiagnosticLogging.rotatedLogFileURL
        )
    ) {
        self.fileWriter = fileWriter
        self.isoFormatter = ISO8601DateFormatter()
        self.isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    public var isDebugLoggingEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isDebugLoggingEnabled
    }

    public var isSaveLogsEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isSaveLogsEnabled
    }

    public func configure(isDebugLoggingEnabled: Bool, isSaveLogsEnabled: Bool) {
        lock.lock()
        _isDebugLoggingEnabled = isDebugLoggingEnabled
        _isSaveLogsEnabled = isSaveLogsEnabled
        lock.unlock()
    }

    public func log(
        level: DiagnosticLogLevel = .debug,
        category: String = "network-recovery",
        _ message: @autoclosure () -> String
    ) {
        let (debugEnabled, saveEnabled) = state()

        if level == .debug, !debugEnabled, !saveEnabled {
            return
        }

        let raw = message()
        let sanitized = DiagnosticLogSanitizer.sanitize(raw)

        // os.Logger output
        if level == .notice {
            let logger = Logger(subsystem: "dev.mudi.mobile", category: category)
            logger.notice("\(sanitized, privacy: .public)")
        } else if level == .error {
            let logger = Logger(subsystem: "dev.mudi.mobile", category: category)
            logger.error("\(sanitized, privacy: .public)")
        } else if level == .debug, debugEnabled {
            let logger = Logger(subsystem: "dev.mudi.mobile", category: category)
            logger.notice("\(sanitized, privacy: .public)")
        }

        // Rolling file persistence
        if saveEnabled {
            let timestamp = lock.withLock { isoFormatter.string(from: Date()) }
            let entry = "\(timestamp) [\(category)] [\(level.rawValue)] \(sanitized)"
            Task {
                await fileWriter.write(entry, enabled: true)
            }
        }
    }

    private func state() -> (debug: Bool, save: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (_isDebugLoggingEnabled, _isSaveLogsEnabled)
    }
}
