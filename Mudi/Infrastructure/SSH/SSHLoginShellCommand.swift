import Foundation

/// Runs an SSH exec command through the remote user's login shell.
///
/// SSH exec requests do not promise the same environment as a login shell, so
/// commands that depend on the user's PATH must be launched with `-l`.
enum SSHLoginShellCommand {
    /// Wraps `command` in a login-shell invocation.
    ///
    /// The fallback is resolved with `command -v` on the remote host rather
    /// than assuming a package-manager prefix. Discovery can use an exit code
    /// of zero when no usable shell is available so ordinary SSH remains an
    /// option; interactive attach keeps the default failure code.
    static func wrap(_ command: String, fallbackExitCode: Int = 127) -> String {
        let quotedCommand = shellQuote(command)
        return """
        SHELL="${SHELL:-}"
        if [ -z "$SHELL" ] || [ ! -x "$SHELL" ]; then
            SHELL="$(command -v sh 2>/dev/null || true)"
        fi
        if [ -n "$SHELL" ] && [ -x "$SHELL" ]; then
            "$SHELL" -lc \(quotedCommand)
        else
            exit \(fallbackExitCode)
        fi
        """
    }

    static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
