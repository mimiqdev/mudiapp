import Foundation
@testable import Mudi
import XCTest

final class Phase9DiagnosticsLoggingTests: XCTestCase {
    private var tempDirectoryURL: URL!

    override func setUp() {
        super.setUp()
        tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mudi-diag-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: tempDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    override func tearDown() {
        if let tempDirectoryURL {
            try? FileManager.default.removeItem(at: tempDirectoryURL)
        }
        super.tearDown()
    }

    func testDiagnosticsTogglesDefaultToFalseAndPersistInPreferences() async throws {
        // Defaults
        let defaultPrefs = TerminalPreferences()
        XCTAssertFalse(defaultPrefs.isDebugLoggingEnabled)
        XCTAssertFalse(defaultPrefs.isSaveLogsEnabled)

        // Backward compatibility: old JSON without diagnostic keys
        let oldJSON = """
        {
            "appearance": "system",
            "fontFamily": "JetBrainsMono Nerd Font Mono",
            "fontSize": 14,
            "hasCompletedLocalNetworkOnboarding": true
        }
        """.data(using: .utf8)!
        let decodedOld = try JSONDecoder().decode(TerminalPreferences.self, from: oldJSON)
        XCTAssertFalse(decodedOld.isDebugLoggingEnabled)
        XCTAssertFalse(decodedOld.isSaveLogsEnabled)

        // Persistence round trip
        let suiteName = "test-prefs-\(UUID().uuidString)"
        let store = makeStore(suiteName: suiteName)
        var prefsToSave = TerminalPreferences()
        prefsToSave.isDebugLoggingEnabled = true
        prefsToSave.isSaveLogsEnabled = true
        try await store.save(prefsToSave)

        let loadedPrefs = try await store.load()
        XCTAssertTrue(loadedPrefs.isDebugLoggingEnabled)
        XCTAssertTrue(loadedPrefs.isSaveLogsEnabled)
    }

    private func makeStore(suiteName: String) -> UserDefaultsPreferencesStore {
        let defaults = UserDefaults(suiteName: suiteName)!
        return UserDefaultsPreferencesStore(defaults: defaults, key: "prefs-key")
    }

    func testDiagnosticLogSanitizerRedactsSensitiveData() {
        // PEM OpenSSH private key
        let opensshHeader = "-----BEGIN " + "OPENSSH PRIVATE KEY-----"
        let opensshFooter = "-----END " + "OPENSSH PRIVATE KEY-----"
        let opensshKey = """
        connect host=example.com key=\(opensshHeader)
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
        \(opensshFooter) done
        """
        let sanitizedOpenSSH = DiagnosticLogSanitizer.sanitize(opensshKey)
        XCTAssertFalse(sanitizedOpenSSH.contains("b3BlbnNzaC1rZXktdjE"))
        XCTAssertFalse(sanitizedOpenSSH.contains("BEGIN OPENSSH PRIVATE KEY"))
        XCTAssertTrue(sanitizedOpenSSH.contains("[REDACTED PRIVATE KEY]"))
        XCTAssertTrue(sanitizedOpenSSH.contains("connect host=example.com"))

        // PEM RSA private key
        let rsaHeader = "-----BEGIN " + "RSA PRIVATE KEY-----"
        let rsaFooter = "-----END " + "RSA PRIVATE KEY-----"
        let rsaKey = """
        \(rsaHeader)
        MIIEowIBAAKCAQEA0Y3rF...
        \(rsaFooter)
        """
        let sanitizedRSA = DiagnosticLogSanitizer.sanitize(rsaKey)
        XCTAssertFalse(sanitizedRSA.contains("MIIEowIBAAKCAQEA0Y3rF"))
        XCTAssertTrue(sanitizedRSA.contains("[REDACTED PRIVATE KEY]"))

        // Password in key-value and JSON
        let kvPassword = "connect host=10.0.0.1:22 password=superSecretPassword123 timeout=10s"
        let sanitizedKV = DiagnosticLogSanitizer.sanitize(kvPassword)
        XCTAssertFalse(sanitizedKV.contains("superSecretPassword123"))
        XCTAssertTrue(sanitizedKV.contains("password=[REDACTED]"))
        XCTAssertTrue(sanitizedKV.contains("host=10.0.0.1:22"))

        let jsonPassword = "{\"username\": \"admin\", \"password\": \"secret456\", \"port\": 22}"
        let sanitizedJSON = DiagnosticLogSanitizer.sanitize(jsonPassword)
        XCTAssertFalse(sanitizedJSON.contains("secret456"))
        XCTAssertTrue(sanitizedJSON.contains("\"password\": \"[REDACTED]\""))
        XCTAssertTrue(sanitizedJSON.contains("\"port\": 22"))

        // Passphrase and Keychain references
        let secretString = "passphrase=mySecretPhrase token=tok_abc123 keychain=item456"
        let sanitizedSecrets = DiagnosticLogSanitizer.sanitize(secretString)
        XCTAssertFalse(sanitizedSecrets.contains("mySecretPhrase"))
        XCTAssertFalse(sanitizedSecrets.contains("tok_abc123"))
        XCTAssertFalse(sanitizedSecrets.contains("item456"))

        // Safe operational fields preserved
        let safeLog = "path change from status=satisfied ifaces=[wifi, cellular] expensive=false"
        XCTAssertEqual(DiagnosticLogSanitizer.sanitize(safeLog), safeLog)
    }

    func testDiagnosticFileWriterAppendsAndDisablingStopsWrites() async throws {
        let logFileURL = tempDirectoryURL.appendingPathComponent("test-debug.log")
        let writer = DiagnosticFileWriter(logFileURL: logFileURL, maxFileSize: 10_000)

        // Write while enabled
        await writer.write("Event 1: network path satisfied", enabled: true)
        let initialData = (try? Data(contentsOf: logFileURL)) ?? Data()
        XCTAssertFalse(initialData.isEmpty)
        let initialText = String(bytes: initialData, encoding: .utf8) ?? ""
        XCTAssertTrue(initialText.contains("Event 1: network path satisfied"))

        // Write while disabled
        let sizeBefore = initialData.count
        await writer.write("Event 2: this should not be written", enabled: false)
        let dataAfter = (try? Data(contentsOf: logFileURL)) ?? Data()
        XCTAssertEqual(dataAfter.count, sizeBefore)
        let textAfter = String(bytes: dataAfter, encoding: .utf8) ?? ""
        XCTAssertFalse(textAfter.contains("Event 2"))
    }

    func testDiagnosticFileWriterRespectsCapAndRotates() async throws {
        let logFileURL = tempDirectoryURL.appendingPathComponent("test-debug.log")
        let rotatedURL = tempDirectoryURL.appendingPathComponent("test-debug.1.log")

        // Cap of 120 bytes so two ~70-byte messages trigger rotation
        let writer = DiagnosticFileWriter(logFileURL: logFileURL, maxFileSize: 120)

        let msg1 = "Message 1: A moderately sized log line that takes some space."
        await writer.write(msg1, enabled: true)

        XCTAssertTrue(FileManager.default.fileExists(atPath: logFileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rotatedURL.path))

        let msg2 = "Message 2: Another line that pushes file size past the cap."
        await writer.write(msg2, enabled: true)

        // Should have rotated
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotatedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: logFileURL.path))

        let rotatedContent = String(bytes: (try? Data(contentsOf: rotatedURL)) ?? Data(), encoding: .utf8) ?? ""
        let activeContent = String(bytes: (try? Data(contentsOf: logFileURL)) ?? Data(), encoding: .utf8) ?? ""

        XCTAssertTrue(rotatedContent.contains("Message 1"))
        XCTAssertTrue(activeContent.contains("Message 2"))
    }

    func testDiagnosticLoggingConstantMatchesStableRelativePath() {
        XCTAssertEqual(DiagnosticLogging.relativeLogPath, "Documents/mudi-debug.log")
        XCTAssertTrue(DiagnosticLogging.logFileURL.path.hasSuffix("Documents/mudi-debug.log"))
    }
}
