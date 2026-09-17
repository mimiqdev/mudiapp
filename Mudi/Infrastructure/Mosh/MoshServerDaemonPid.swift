import Foundation

/// The remote `mosh-server` daemon pid printed on stderr after `mosh-server new`.
///
/// Live mosh 1.4.0 writes `[mosh-server detached, pid = N]` to stderr and only
/// `MOSH CONNECT <port> <key>` to stdout. The pid is the detached daemon
/// (PPID 1). The attach child is not printed. The fake test string
/// `mosh-server pid=4112` is not this line and must not parse.
enum MoshServerDaemonPid {
    static func parse(from output: String) -> Int32? {
        let normalized = output.replacingOccurrences(of: "\r\n", with: "\n")
        for rawLine in normalized.split(
            omittingEmptySubsequences: false,
            whereSeparator: \.isNewline
        ) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("[mosh-server detached, pid = "),
                  line.hasSuffix("]")
            else { continue }
            let digits = line.dropFirst("[mosh-server detached, pid = ".count).dropLast()
            guard let pid = Int32(digits), pid > 1 else { continue }
            return pid
        }
        return nil
    }

    static func terminateCommand(pid: Int32) -> String {
        SSHLoginShellCommand.wrap("kill -TERM \(pid)")
    }
}
