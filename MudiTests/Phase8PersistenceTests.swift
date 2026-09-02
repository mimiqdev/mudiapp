import Foundation
import XCTest
@testable import Mudi

final class Phase8PersistenceTests: XCTestCase {
    func testThemeAndFontPreferencesSurviveSaveLoadForAutomaticAndFixedSelections() async throws {
        let selections: [TerminalThemeSelection] = [
            .automatic(
                light: "Solarized Light",
                dark: "Solarized Dark"
            ),
            .fixedLight("Catppuccin Latte"),
            .fixedDark("Catppuccin Mocha"),
        ]

        for selection in selections {
            let data = try phase8StoredPreferencesData(
                selection: selection,
                fontFamily: "Phase 8 Mono",
                fontSize: 19.5
            )
            let loaded = try await roundTrip(data: data)
            let fields: [String: Any] = Dictionary(
                uniqueKeysWithValues: Mirror(reflecting: loaded).children.compactMap {
                    child in
                    guard let label = child.label else { return nil }
                    return (label, child.value)
                }
            )

            XCTAssertEqual(
                fields["appearance"] as? AppearancePreference,
                .system
            )
            XCTAssertEqual(fields["fontSize"] as? Double, 19.5)
            XCTAssertEqual(
                fields["fontFamily"] as? String,
                "Phase 8 Mono",
                "The selected family must survive a preference restart"
            )
            let themeDescription = String(describing: fields["themeSelection"] as Any)
            switch selection {
            case let .automatic(light, dark):
                XCTAssertTrue(themeDescription.contains(light))
                XCTAssertTrue(themeDescription.contains(dark))
            case let .fixedLight(name), let .fixedDark(name):
                XCTAssertTrue(themeDescription.contains(name))
            }
        }
    }

    private func roundTrip(data: Data) async throws -> TerminalPreferences {
        let suiteName = "dev.mudi.phase8.preferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set(data, forKey: "terminal-preferences")

        let store = UserDefaultsPreferencesStore(
            defaults: defaults,
            key: "terminal-preferences"
        )
        let loaded = try await store.load()
        try await store.save(loaded)
        return try await store.load()
    }
}
