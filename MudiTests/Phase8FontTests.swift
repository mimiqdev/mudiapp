import CoreText
import Foundation
import UIKit
import XCTest
@testable import Mudi

@MainActor
final class Phase8FontTests: XCTestCase {
    func testBundledFontResourcesContainARealMonospaceFaceAndNerdGlyphs() throws {
        let bundle = phase8AppBundle()
        let fontURLs = (bundle.urls(
            forResourcesWithExtension: "ttf",
            subdirectory: nil
        ) ?? []) + (bundle.urls(
            forResourcesWithExtension: "otf",
            subdirectory: nil
        ) ?? [])
        XCTAssertFalse(
            fontURLs.isEmpty,
            "The app must bundle at least one distributable terminal font"
        )

        var foundUsableTerminalFont = false
        for url in fontURLs {
            guard let font = phase8Font(from: url) else {
                XCTFail("Unable to create a CTFont from \(url.lastPathComponent)")
                continue
            }
            XCTAssertGreaterThan(CTFontGetAscent(font), 0)
            XCTAssertGreaterThan(CTFontGetDescent(font), 0)
            XCTAssertGreaterThan(CTFontGetUnitsPerEm(font), 0)

            let glyphs = phase8Glyphs(in: font)
            if glyphs.latin != 0, glyphs.nerd != 0 {
                foundUsableTerminalFont = true
            }
        }
        XCTAssertTrue(
            foundUsableTerminalFont,
            "A bundled face must provide both ordinary monospace text and a Nerd Font glyph; a symbols-only fallback is insufficient"
        )
    }

    func testBundledFontRegistryRecordsResourcesLicensesAndMetrics() throws {
        let descriptors = TerminalFontRegistry.bundledFonts
        XCTAssertFalse(
            descriptors.isEmpty,
            "Bundled font metadata must be registered, not inferred only at render time"
        )

        var hasNerdFont = false
        for descriptor in descriptors {
            XCTAssertFalse(descriptor.familyName.isEmpty)
            XCTAssertFalse(descriptor.resourceName.isEmpty)
            XCTAssertTrue(["ttf", "otf"].contains(descriptor.fileExtension.lowercased()))
            XCTAssertFalse(descriptor.license.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertEqual(URL(string: descriptor.sourceURL)?.scheme, "https")

            let url = try XCTUnwrap(
                phase8AppBundle().url(
                    forResource: descriptor.resourceName,
                    withExtension: descriptor.fileExtension
                )
            )
            let font = try XCTUnwrap(phase8Font(from: url))
            XCTAssertGreaterThan(CTFontGetAscent(font), 0)
            XCTAssertGreaterThan(CTFontGetDescent(font), 0)
            let glyphs = phase8Glyphs(in: font)
            if glyphs.nerd != 0 {
                hasNerdFont = true
            }
        }
        XCTAssertTrue(hasNerdFont)
    }

    func testSwiftTermUsesTheSelectedBundledFontFamilyAndPointSize() throws {
        let descriptor = try XCTUnwrap(TerminalFontRegistry.bundledFonts.first)
        let selection = TerminalFontSelection(
            familyName: descriptor.familyName,
            pointSize: 18
        )
        let selectedFont = try XCTUnwrap(
            TerminalFontRegistry.font(
                familyName: selection.familyName,
                pointSize: selection.pointSize
            )
        )
        XCTAssertEqual(selectedFont.familyName, selection.familyName)
        XCTAssertEqual(selectedFont.pointSize, selection.pointSize, accuracy: 0.001)

        let terminalView = ShellTerminalView(frame: .zero)
        terminalView.font = selectedFont
        terminalView.updateFontSize(selection.pointSize)
        XCTAssertEqual(
            terminalView.font.familyName,
            selection.familyName,
            "SwiftTerm must keep the selected family instead of replacing it with a system fallback"
        )
        XCTAssertEqual(terminalView.font.pointSize, selection.pointSize, accuracy: 0.001)

        let glyphs = phase8Glyphs(in: phase8CTFont(from: terminalView.font))
        XCTAssertNotEqual(
            glyphs.nerd,
            0,
            "The selected SwiftTerm font must render Nerd symbols"
        )
        terminalView.stop()
    }

    func testDocumentPickerAcceptsTTFAndOTFFileExtensions() {
        XCTAssertEqual(
            Set(TerminalFontRegistry.supportedFileExtensions.map { $0.lowercased() }),
            Set(["ttf", "otf"]),
            "The document picker must advertise both supported font formats"
        )
    }

    func testDocumentPickerKeepsLatinOnlyFamilyAndAddsNerdCascade() throws {
        let source = try XCTUnwrap(
            Bundle(for: Phase8FontTests.self).url(
                forResource: "Hack-Regular",
                withExtension: "ttf"
            )
        )
        let importedURL = try phase8TemporaryFontURL(
            source: source,
            fileExtension: "ttf"
        )
        defer { try? FileManager.default.removeItem(at: importedURL) }

        let familyName = try XCTUnwrap(
            TerminalFontRegistry.registerImportedFont(at: importedURL),
            "The Latin-only fixture should register as a selectable family"
        )
        XCTAssertNotEqual(familyName, TerminalFontRegistry.defaultFamilyName)
        let font = try XCTUnwrap(
            TerminalFontRegistry.font(
                familyName: familyName,
                pointSize: 16
            )
        )
        XCTAssertEqual(font.familyName, familyName)
        XCTAssertTrue(
            TerminalFont.hasSymbolsCascade(in: font),
            "A Latin-only imported face should receive the bundled Nerd cascade"
        )
    }

    func testDocumentPickerCallbackRegistersARealTTFFontAsSelectableFamily() throws {
        let source = try XCTUnwrap(
            phase8AppBundle().url(
                forResource: "SymbolsNerdFontMono-Regular",
                withExtension: "ttf"
            )
        )
        let importedURL = try phase8TemporaryFontURL(
            source: source,
            fileExtension: "ttf"
        )
        defer { try? FileManager.default.removeItem(at: importedURL) }

        // This closure is the seam a UIDocumentPicker callback uses after it
        // receives a security-scoped URL from the user. The format-acceptance
        // test above covers .otf without pretending this TTF has OTF bytes.
        let documentPickerCallback: (URL) -> String? =
            TerminalFontRegistry.registerImportedFont(at:)
        let familyName = try XCTUnwrap(
            documentPickerCallback(importedURL),
            "The document picker must register a real .ttf font"
        )
        XCTAssertTrue(
            TerminalFontRegistry.availableFamilyNames.contains(familyName),
            "An imported font must become selectable immediately"
        )
        let font = try XCTUnwrap(
            TerminalFontRegistry.font(
                familyName: familyName,
                pointSize: 16
            )
        )
        XCTAssertEqual(font.familyName, familyName)
        XCTAssertEqual(font.pointSize, 16, accuracy: 0.001)
        XCTAssertNotEqual(
            phase8Glyphs(in: phase8CTFont(from: font)).nerd,
            0,
            "The imported family must render Nerd symbols when selected"
        )
    }
}
