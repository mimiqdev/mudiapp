import Foundation

public actor DiagnosticFileWriter {
    public let logFileURL: URL
    public let rotatedLogFileURL: URL
    public let maxFileSize: Int64

    public init(
        logFileURL: URL,
        rotatedLogFileURL: URL? = nil,
        maxFileSize: Int64 = 1_048_576 // 1 MB default
    ) {
        self.logFileURL = logFileURL
        if let rotatedLogFileURL {
            self.rotatedLogFileURL = rotatedLogFileURL
        } else {
            let directory = logFileURL.deletingLastPathComponent()
            let baseName = logFileURL.deletingPathExtension().lastPathComponent
            let ext = logFileURL.pathExtension
            self.rotatedLogFileURL = directory
                .appendingPathComponent("\(baseName).1.\(ext)")
        }
        self.maxFileSize = maxFileSize
    }

    public func write(_ message: String, enabled: Bool) {
        guard enabled else { return }

        let line = message.hasSuffix("\n") ? message : message + "\n"
        let data = Data(line.utf8)
        ensureDirectoryExists()

        let currentSize = fileSize(at: logFileURL)
        if currentSize + Int64(data.count) > maxFileSize, currentSize > 0 {
            rotate()
        }

        append(data)
    }

    private func ensureDirectoryExists() {
        let directory = logFileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
    }

    private func fileSize(at url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int64
        else {
            return 0
        }
        return size
    }

    private func rotate() {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: rotatedLogFileURL.path) {
            try? fileManager.removeItem(at: rotatedLogFileURL)
        }
        if fileManager.fileExists(atPath: logFileURL.path) {
            try? fileManager.moveItem(at: logFileURL, to: rotatedLogFileURL)
        }
    }

    private func append(_ data: Data) {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: logFileURL.path) {
            fileManager.createFile(atPath: logFileURL.path, contents: data)
            return
        }

        guard let handle = try? FileHandle(forWritingTo: logFileURL) else {
            return
        }
        defer { try? handle.close() }

        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Drop unwriteable entry gracefully rather than crashing.
        }
    }
}
