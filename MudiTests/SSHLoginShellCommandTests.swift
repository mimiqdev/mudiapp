import XCTest
@testable import Mudi

final class SSHLoginShellCommandTests: XCTestCase {
    func testWrapUsesConfiguredShellAsLoginShell() {
        let command = SSHLoginShellCommand.wrap("herdr session list --json")

        XCTAssertTrue(command.contains(#"SHELL="${SHELL:-}"#))
        XCTAssertTrue(command.contains(#""$SHELL" -lc 'herdr session list --json'"#))
        XCTAssertFalse(command.contains("export PATH"))
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

        XCTAssertTrue(command.contains(#"'herdr --session '\''named'\'' workspace list'"#))
    }
}
