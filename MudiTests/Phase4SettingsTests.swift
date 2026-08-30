import XCTest
@testable import Mudi

final class Phase4SettingsTests: XCTestCase {
    func testAppearanceOffersSystemLightAndDarkAndDefaultsToSystem() async throws {
        let store = MissingPhase4PreferencesStore()
        let preferences = try await store.load()

        XCTAssertEqual(
            Phase4Appearance.allCases,
            [.system, .light, .dark]
        )
        XCTAssertEqual(preferences.appearance, .system)
    }

    func testSavingThenLoadingRestoresTheLastAppearanceChoice() async throws {
        let store = MissingPhase4PreferencesStore()
        let saved = Phase4TerminalPreferences(appearance: .dark)

        try await store.save(saved)
        let loaded = try await store.load()

        XCTAssertEqual(loaded.appearance, .dark)
    }

    func testTerminalFontSizeCanBeReadWrittenAndRestored() async throws {
        let store = MissingPhase4PreferencesStore()
        let saved = Phase4TerminalPreferences(fontSize: 19.5)

        try await store.save(saved)
        let loaded = try await store.load()

        XCTAssertEqual(loaded.fontSize, saved.fontSize, accuracy: 0.001)
    }
}
