import Foundation

/// Runs an SSH exec command through the remote user's login shell.
///
/// SSH exec requests do not promise the same environment as a login shell, so
/// commands that depend on the user's PATH must be launched with `-l`.
///
/// A login shell also skips the interactive startup files that add user-local
/// tool directories. mise activates its version shims from `~/.zshrc`, so a
/// `herdr` installed through mise is invisible to `ssh host 'herdr ...'` even
/// though the user's interactive shell finds it. Discovery then reported no
/// sessions while the remote server was running. Every command therefore
/// starts from the user's login-shell `PATH` and appends the standard
/// user-local executable directories.
enum SSHLoginShellCommand {
    /// The standard user-local executable directories interactive startup
    /// files add to `PATH`. Paths stay `$HOME`-relative: no host, user, or
    /// package-manager prefix is assumed.
    static let userLocalExecutableDirectories = [
        "$HOME/.local/share/mise/shims",
        "$HOME/.local/bin",
    ]

    /// Appends the user-local directories to the login shell's `PATH`.
    ///
    /// The login shell's own directories stay first, so every executable that
    /// already resolved keeps resolving to the same one; the appended entries
    /// only make previously invisible user-local tools reachable.
    static var pathBootstrap: String {
        let appended = userLocalExecutableDirectories.joined(separator: ":")
        return "PATH=\"$PATH:\(appended)\"; export PATH"
    }

    /// Command body executed by the login shell: the user-local `PATH`,
    /// optional environment exports, then the caller's command.
    static func loginShellBody(
        _ command: String,
        environment: [String: String] = [:]
    ) -> String {
        var parts = [pathBootstrap]
        if !environment.isEmpty {
            parts += environment.keys.sorted().map { name in
                "export \(name)=\(shellQuote(environment[name] ?? ""))"
            }
        }
        parts.append(command)
        return parts.joined(separator: "; ")
    }

    /// Wraps `command` in a login-shell invocation.
    ///
    /// The fallback is resolved with `command -v` on the remote host rather
    /// than assuming a package-manager prefix. Discovery can use an exit code
    /// of zero when no usable shell is available so ordinary SSH remains an
    /// option; interactive attach keeps the default failure code.
    static func wrap(
        _ command: String,
        fallbackExitCode: Int = 127,
        environment: [String: String] = [:]
    ) -> String {
        let quotedBody = shellQuote(loginShellBody(command, environment: environment))
        return """
        SHELL="${SHELL:-}"
        if [ -z "$SHELL" ] || [ ! -x "$SHELL" ]; then
            SHELL="$(command -v sh 2>/dev/null || true)"
        fi
        if [ -n "$SHELL" ] && [ -x "$SHELL" ]; then
            "$SHELL" -lc \(quotedBody)
        else
            exit \(fallbackExitCode)
        fi
        """
    }

    /// Wraps an interactive/PTY command in the user's login shell with the
    /// same user-local executable path. The command keeps the PTY
    /// channel-level environment exports it already carries, so only the
    /// login shell and `PATH` are added here.
    static func wrapInteractive(_ command: String) -> String {
        "\"${SHELL:-/bin/sh}\" -lc \(shellQuote(loginShellBody(command)))"
    }

    static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
