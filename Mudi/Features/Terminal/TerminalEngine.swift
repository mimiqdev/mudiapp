import Foundation

/// Stored preference, not the identity of an already-mounted terminal.
enum TerminalEnginePreference: String, Codable, CaseIterable, Sendable {
    case swiftTerm
    case ghosttyVT

    var label: String {
        switch self {
        case .swiftTerm: "SwiftTerm（默认）"
        case .ghosttyVT: "Ghostty VT（实验）"
        }
    }
}
