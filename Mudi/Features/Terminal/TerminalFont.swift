import CoreText
import Foundation
import UIKit

/// Provides the system terminal face with bundled Nerd Font symbols as a
/// fallback. The bundled Symbols Nerd Font is intentionally not used for
/// ordinary letters; the upstream release describes it as a fallback font.
@MainActor
enum TerminalFont {
    static let defaultPointSize = 14.0
    private static let symbolsFamilyName = "Symbols Nerd Font Mono"
    private static var didRegisterSymbols = false

    static func hasSymbolsCascade(in font: UIFont) -> Bool {
        guard let cascadeList = font.fontDescriptor.object(
            forKey: .cascadeList
        ) as? [UIFontDescriptor]
        else { return false }

        return cascadeList.contains { descriptor in
            descriptor.object(forKey: .family) as? String == symbolsFamilyName
        }
    }

    static func font(ofSize size: Double) -> UIFont {
        guard size.isFinite, size > 0 else {
            return UIFont.monospacedSystemFont(
                ofSize: defaultPointSize,
                weight: .regular
            )
        }

        registerSymbolsIfNeeded()
        let pointSize = CGFloat(size)
        let baseFont = UIFont.monospacedSystemFont(
            ofSize: pointSize,
            weight: .regular
        )
        guard let symbolsFont = UIFont(
            name: symbolsFamilyName,
            size: pointSize
        ) else {
            return baseFont
        }

        let descriptor = baseFont.fontDescriptor.addingAttributes([
            .cascadeList: [symbolsFont.fontDescriptor]
        ])
        return UIFont(descriptor: descriptor, size: pointSize)
    }

    private static func registerSymbolsIfNeeded() {
        guard !didRegisterSymbols,
              let url = TerminalFontRegistry.appBundle.url(
                  forResource: "SymbolsNerdFontMono-Regular",
                  withExtension: "ttf"
              )
        else { return }

        var error: Unmanaged<CFError>?
        _ = CTFontManagerRegisterFontsForURL(
            url as CFURL,
            .process,
            &error
        )
        didRegisterSymbols = true
    }
}

/// Registers bundled and user-imported terminal faces once per process and
/// keeps the metadata needed to make them safe, selectable choices in the UI.
@MainActor
enum TerminalFontRegistry {
    static let defaultFamilyName = "JetBrainsMono Nerd Font Mono"
    static let supportedFileExtensions: Set<String> = ["ttf", "otf"]

    private static let bundledFontDescriptors = [
        TerminalFontDescriptor(
            familyName: defaultFamilyName,
            resourceName: "JetBrainsMonoNerdFontMono-Regular",
            fileExtension: "ttf",
            license: "SIL Open Font License 1.1 (JetBrains Mono); Nerd Fonts patch attribution retained",
            sourceURL: "https://github.com/ryanoasis/nerd-fonts"
        )
    ]
    private static var didRegisterBundledFonts = false
    private static var didScanImportedFonts = false
    private static var importedFonts: [String: URL] = [:]

    static var appBundle: Bundle {
        Bundle(identifier: "dev.mudi.mobile") ?? Bundle.main
    }

    static var bundledFonts: [TerminalFontDescriptor] {
        registerBundledFontsIfNeeded()
        return bundledFontDescriptors
    }

    static var availableFamilyNames: [String] {
        registerBundledFontsIfNeeded()
        return Array(
            Set(bundledFontDescriptors.map(\.familyName) + importedFonts.keys)
        ).sorted()
    }

    static func font(familyName: String, pointSize: Double) -> UIFont? {
        guard pointSize.isFinite, pointSize > 0 else { return nil }
        registerBundledFontsIfNeeded()
        guard availableFamilyNames.contains(familyName),
              let selectedFont = UIFont(name: familyName, size: CGFloat(pointSize))
        else { return nil }

        guard importedFonts[familyName] != nil else {
            return selectedFont
        }

        var cascadeList: [UIFontDescriptor] = []
        if !supportsLatinGlyph(familyName) {
            // A symbols-only Nerd Font needs an ordinary text fallback.
            let fallback = UIFont.monospacedSystemFont(
                ofSize: CGFloat(pointSize),
                weight: .regular
            )
            cascadeList.append(fallback.fontDescriptor)
        }
        if !supportsNerdGlyph(familyName),
           let symbolsFont = symbolsFont(ofSize: pointSize) {
            // A normal imported face can remain the selected primary family;
            // Nerd glyphs are added as a rendering cascade instead.
            cascadeList.append(symbolsFont.fontDescriptor)
        }
        guard !cascadeList.isEmpty else { return selectedFont }

        let descriptor = selectedFont.fontDescriptor.addingAttributes([
            .cascadeList: cascadeList
        ])
        return UIFont(descriptor: descriptor, size: CGFloat(pointSize))
    }

    /// Copies an imported file into the app support directory before process
    /// registration. This makes a security-scoped document URL safe to use
    /// after the picker callback returns and avoids retaining a transient URL.
    @discardableResult
    static func registerImportedFont(at url: URL) -> String? {
        registerBundledFontsIfNeeded()
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard supportedFileExtensions.contains(url.pathExtension.lowercased()),
              let destination = copyToFontSupportDirectory(url),
              let familyNames = registerFont(at: destination),
              !familyNames.isEmpty
        else { return nil }

        for familyName in familyNames {
            importedFonts[familyName] = destination
        }
        didScanImportedFonts = true

        if let familyName = familyNames.first(where: supportsLatinGlyph) {
            return familyName
        }

        // A symbols-only Nerd Font is useful as a cascade, but it is not a
        // complete terminal face. Select the bundled full face in that case
        // so the picker always hands SwiftTerm one UIFont that maps ordinary
        // text and Nerd glyphs together. Reject unrelated files instead of
        // silently replacing an ordinary imported font with JetBrains Mono.
        guard familyNames.contains(where: supportsNerdGlyph) else { return nil }
        return defaultFamilyName
    }

    private static func registerBundledFontsIfNeeded() {
        guard !didRegisterBundledFonts else { return }
        didRegisterBundledFonts = true

        for descriptor in bundledFontDescriptors {
            guard let url = appBundle.url(
                forResource: descriptor.resourceName,
                withExtension: descriptor.fileExtension
            ) else { continue }
            _ = registerFont(at: url)
        }
        scanImportedFontsIfNeeded()
    }

    private static func scanImportedFontsIfNeeded() {
        guard !didScanImportedFonts else { return }
        didScanImportedFonts = true
        let directory = fontSupportDirectory()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }

        for file in files where supportedFileExtensions.contains(
            file.pathExtension.lowercased()
        ) {
            guard let familyNames = registerFont(at: file) else { continue }
            for familyName in familyNames {
                importedFonts[familyName] = file
            }
        }
    }

    private static func supportsLatinGlyph(_ familyName: String) -> Bool {
        supportsGlyph(familyName, character: 77)
    }

    private static func supportsNerdGlyph(_ familyName: String) -> Bool {
        supportsGlyph(familyName, character: 0xf07b)
    }

    private static func supportsGlyph(
        _ familyName: String,
        character: UniChar
    ) -> Bool {
        guard let font = UIFont(name: familyName, size: 16) else { return false }
        let ctFont = CTFontCreateWithFontDescriptor(
            font.fontDescriptor,
            font.pointSize,
            nil
        )
        var characters: [UniChar] = [character]
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        guard CTFontGetGlyphsForCharacters(
            ctFont,
            &characters,
            &glyphs,
            characters.count
        ) else { return false }
        return glyphs[0] != 0
    }

    private static var didRegisterSymbols = false

    private static func symbolsFont(ofSize size: Double) -> UIFont? {
        registerSymbolsIfNeeded()
        return UIFont(name: "Symbols Nerd Font Mono", size: CGFloat(size))
    }

    private static func registerSymbolsIfNeeded() {
        guard !didRegisterSymbols else { return }
        didRegisterSymbols = true
        guard let url = appBundle.url(
            forResource: "SymbolsNerdFontMono-Regular",
            withExtension: "ttf"
        ) else { return }

        var error: Unmanaged<CFError>?
        _ = CTFontManagerRegisterFontsForURL(
            url as CFURL,
            .process,
            &error
        )
    }

    private static func registerFont(at url: URL) -> [String]? {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(
            url as CFURL
        ) as? [CTFontDescriptor], !descriptors.isEmpty else {
            return nil
        }

        var error: Unmanaged<CFError>?
        _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)

        let families = descriptors.compactMap { descriptor in
            CTFontDescriptorCopyAttribute(
                descriptor,
                kCTFontFamilyNameAttribute
            ) as? String
        }
        return Array(Set(families)).sorted()
    }

    private static func copyToFontSupportDirectory(_ url: URL) -> URL? {
        let directory = fontSupportDirectory()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let destination = directory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(url.pathExtension.lowercased())
            try FileManager.default.copyItem(at: url, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    private static func fontSupportDirectory() -> URL {
        let baseURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent("Mudi", isDirectory: true)
            .appendingPathComponent("Fonts", isDirectory: true)
    }
}
