import Foundation

/// Stored preference, not the identity of an already-mounted terminal.
enum TerminalEnginePreference: String, Codable, CaseIterable, Sendable {
    case swiftTerm
    case ghosttyVT

    var label: String {
        switch self {
        case .swiftTerm: MudiL10n.text("SwiftTerm（默认）")
        case .ghosttyVT: MudiL10n.text("Ghostty VT（实验）")
        }
    }
}
