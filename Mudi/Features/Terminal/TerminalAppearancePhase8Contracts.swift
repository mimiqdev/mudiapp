import Foundation
import UIKit

/// The value contract for the phase-8 terminal theme registry.
///
/// The registry is intentionally empty until the appearance implementation is
/// added. Keeping the value shape here lets the red tests describe the
/// boundary without hard-coding theme colours in the test target.
struct TerminalRGBColor: Codable, Equatable, Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
}

enum TerminalThemeVariant: String, Codable, CaseIterable, Sendable {
    case light
    case dark
}

enum TerminalThemePaletteStrategy: Codable, Equatable, Sendable {
    case xterm
    case base16Lab
    case base16LabHarmonious
    case explicit([TerminalRGBColor])
}

struct TerminalThemeSource: Codable, Equatable, Sendable {
    let repositoryURL: String
    let license: String
    let attribution: String
}

struct TerminalTheme: Codable, Equatable, Sendable {
    let name: String
    let family: String
    let variant: TerminalThemeVariant
    let ansi16: [TerminalRGBColor]
    let defaultForeground: TerminalRGBColor
    let defaultBackground: TerminalRGBColor
    let bold: TerminalRGBColor
    let cursor: TerminalRGBColor
    let selection: TerminalRGBColor
    let extendedPaletteStrategy: TerminalThemePaletteStrategy
    let extendedPaletteDocumentation: String
    let source: TerminalThemeSource
}

enum TerminalThemeSelection: Codable, Equatable, Sendable {
    case automatic(light: String, dark: String)
    case fixedLight(String)
    case fixedDark(String)
}

enum TerminalThemeRegistry {
    static var builtInThemes: [TerminalTheme] { [] }

    static func theme(named name: String) -> TerminalTheme? {
        builtInThemes.first { $0.name == name }
    }

    static func resolve(
        _ selection: TerminalThemeSelection,
        for variant: TerminalThemeVariant
    ) -> TerminalTheme? {
        let name: String
        switch selection {
        case let .automatic(light, dark):
            name = variant == .light ? light : dark
        case let .fixedLight(fixedName), let .fixedDark(fixedName):
            name = fixedName
        }
        return theme(named: name)
    }
}

struct TerminalFontDescriptor: Codable, Equatable, Sendable {
    let familyName: String
    let resourceName: String
    let fileExtension: String
    let license: String
    let sourceURL: String
}

struct TerminalFontSelection: Codable, Equatable, Sendable {
    let familyName: String
    let pointSize: Double
}

enum TerminalFontRegistry {
    static var bundledFonts: [TerminalFontDescriptor] { [] }
    static var availableFamilyNames: [String] { [] }
    static var supportedFileExtensions: Set<String> { [] }

    static func registerImportedFont(at _: URL) -> String? {
        nil
    }

    static func font(
        familyName _: String,
        pointSize _: Double
    ) -> UIFont? {
        nil
    }
}

enum TerminalSessionKind: String, CaseIterable, Codable, Sendable {
    case sshShell
    case sshControlChannel
    case moshBootstrap
}

struct TerminalPTYCapabilityDeclaration: Codable, Equatable, Sendable {
    let sessionKind: TerminalSessionKind
    let environment: [String: String]
}

enum TerminalPTYCapabilities {
    static var declarations: [TerminalPTYCapabilityDeclaration] { [] }
}

/// Minimal product seam for applying the complete phase-8 theme to the real
/// SwiftTerm-backed view. The no-op declaration keeps the red tests compiling;
/// the appearance implementation must replace it with the actual application.
extension ShellTerminalView {
    var appliedTheme: TerminalTheme? { nil }

    func apply(theme _: TerminalTheme) {}
}
