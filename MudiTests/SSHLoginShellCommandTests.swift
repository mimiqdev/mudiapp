import XCTest
@testable import Mudi

final class SSHLoginShellCommandTests: XCTestCase {
    /// The standard user-local executable directories a user's interactive
    /// startup files add to `PATH` but a noninteractive login shell does not:
    /// mise's default shim directory and `~/.local/bin`. Kept `$HOME`-relative
    /// because no host, user, or package-manager prefix may be special-cased.
    private static let userLocalPathAppend =
        #"PATH="$PATH:$HOME/.local/share/mise/shims:$HOME/.local/bin"; export PATH"#

    func testWrapUsesConfiguredShellAsLoginShell() {
        let command = SSHLoginShellCommand.wrap("herdr session list --json")

        XCTAssertTrue(command.contains(#"SHELL="${SHELL:-}"#))
        XCTAssertTrue(command.contains(#""$SHELL" -lc '"#))
    }

    /// macmini regression: `zsh -lc` never reads `~/.zshrc`, where mise
    /// activates its version shims, so a mise-managed `herdr` was invisible to
    /// noninteractive SSH and Mudi showed "No Herdr Sessions".
    func testWrapAppendsUserLocalExecutableDirectoriesToTheLoginShellPATH() {
        let command = SSHLoginShellCommand.wrap("herdr session list --json")

        XCTAssertTrue(
            command.contains(Self.userLocalPathAppend),
            "A mise-managed herdr must resolve in the noninteractive login shell"
        )
        XCTAssertTrue(
            command.contains(
                #""$SHELL" -lc '\#(Self.userLocalPathAppend); herdr session list --json'"#
            )
        )
    }

    func testWrapKeepsLoginShellDirectoriesAheadOfUserLocalOnes() {
        let command = SSHLoginShellCommand.wrap("herdr session list --json")

        // `$PATH` stays first: an executable the login shell already resolves
        // keeps resolving to the same one. The appended entries only make
        // previously invisible user-local tools reachable.
        XCTAssertTrue(command.contains(#""$SHELL" -lc 'PATH="$PATH:"#))
    }

    func testWrapNeverHardcodesHostSpecificExecutablePaths() {
        let command = SSHLoginShellCommand.wrap("herdr session list --json")

        XCTAssertFalse(command.contains("/Users/"))
        XCTAssertFalse(command.contains("/home/"))
        XCTAssertFalse(command.contains("shinymimiq"))
        XCTAssertFalse(command.contains("/opt/homebrew"))
        XCTAssertFalse(command.contains("mise activate"))
    }

    func testWrapFindsAnAvailableFallbackLoginShell() {
        let command = SSHLoginShellCommand.wrap("herdr session list --json")

        XCTAssertTrue(command.contains("command -v sh"))
        XCTAssertTrue(command.contains(#"[ -x "$SHELL" ]"#))
        XCTAssertTrue(command.contains(#""$SHELL" -lc"#))
        XCTAssertFalse(command.contains("/opt/homebrew/bin"))
        XCTAssertFalse(command.contains("/usr/local/bin"))
        XCTAssertFalse(command.contains("linuxbrew"))
    }

    func testWrapShellQuotesTheRemoteCommand() {
        let command = SSHLoginShellCommand.wrap("herdr --session 'named' workspace list")

        XCTAssertTrue(
            command.contains(#"herdr --session '\''named'\'' workspace list'"#)
        )
    }

    func testWrapInteractiveUsesTheLoginShellWithTheUserLocalPATH() {
        let command = SSHLoginShellCommand.wrapInteractive(
            "exec herdr terminal attach 'term_1' --takeover"
        )

        XCTAssertTrue(command.hasPrefix(#""${SHELL:-/bin/sh}" -lc '"#))
        XCTAssertTrue(command.contains(Self.userLocalPathAppend))
        XCTAssertTrue(command.contains(#"exec herdr terminal attach '\''term_1'\'' --takeover"#))
    }
}
