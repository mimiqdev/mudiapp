import Foundation

public enum DiagnosticLogSanitizer: Sendable {
    private static let pemRegex: NSRegularExpression? = {
        let pattern = #"-----BEGIN [A-Z0-9_-]+ PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9_-]+ PRIVATE KEY-----"#
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    private static let pemHeaderRegex: NSRegularExpression? = {
        let pattern = #"-----BEGIN [A-Z0-9_-]+ PRIVATE KEY-----.*"#
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    private static let kvSecretRegex: NSRegularExpression? = {
        let pattern = #"(?i)\b(password|passphrase|secret|token|keychain)[ \t]*(=|:)[ \t]*(".*?"|'.*?'|[^\s,;]+)"#
        return try? NSRegularExpression(pattern: pattern, options: [])
    }()

    private static let jsonSecretRegex: NSRegularExpression? = {
        let pattern = #"(?i)"(password|passphrase|secret|token|keychain)"[ \t]*:[ \t]*"[^"]*""#
        return try? NSRegularExpression(pattern: pattern, options: [])
    }()

    private static let herdrSnapshotRegex: NSRegularExpression? = {
        let pattern = #"HerdrSnapshot\([\s\S]*?\)"#
        return try? NSRegularExpression(pattern: pattern, options: [])
    }()

    public static func sanitize(_ message: String) -> String {
        var result = message

        // Redact full PEM private key blocks
        if let pemRegex {
            let range = NSRange(result.startIndex..., in: result)
            result = pemRegex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: "[REDACTED PRIVATE KEY]"
            )
        }

        // Redact unclosed PEM private key headers
        if let pemHeaderRegex {
            let range = NSRange(result.startIndex..., in: result)
            result = pemHeaderRegex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: "[REDACTED PRIVATE KEY]"
            )
        }

        // Redact JSON secrets: "password": "..." -> "password": "[REDACTED]"
        if let jsonSecretRegex {
            let range = NSRange(result.startIndex..., in: result)
            result = jsonSecretRegex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: "\"$1\": \"[REDACTED]\""
            )
        }

        // Redact KV secrets: password=... -> password=[REDACTED]
        if let kvSecretRegex {
            let range = NSRange(result.startIndex..., in: result)
            result = kvSecretRegex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: "$1$2[REDACTED]"
            )
        }

        // Redact verbose Herdr snapshots
        if let herdrSnapshotRegex {
            let range = NSRange(result.startIndex..., in: result)
            result = herdrSnapshotRegex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: "[REDACTED HERDR SNAPSHOT]"
            )
        }

        return result
    }
}
