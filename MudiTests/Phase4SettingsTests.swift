import Foundation
import XCTest
@testable import Mudi

final class Phase4SettingsTests: XCTestCase {
    func testAppearanceOffersSystemLightAndDarkAndDefaultsToSystem() async throws {
        let store = makeStore()

        let preferences = try await store.load()

        XCTAssertEqual(
            AppearancePreference.allCases,
            [.system, .light, .dark]
        )
        XCTAssertEqual(preferences.appearance, .system)
    }

    func testSavingThenLoadingRestoresTheLastAppearanceChoice() async throws {
        let store = makeStore()
        let saved = TerminalPreferences(appearance: .dark)

        try await store.save(saved)
        let loaded = try await store.load()

        XCTAssertEqual(loaded.appearance, .dark)
    }

    func testTerminalFontSizeCanBeReadWrittenAndRestored() async throws {
        let store = makeStore()
        let saved = TerminalPreferences(fontSize: 19.5)

        try await store.save(saved)
        let loaded = try await store.load()

        XCTAssertEqual(loaded.fontSize, saved.fontSize, accuracy: 0.001)
    }

    private func makeStore() -> UserDefaultsPreferencesStore {
        let suiteName = "dev.mudi.phase4.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return UserDefaultsPreferencesStore(
            defaults: defaults,
            key: "terminal-preferences"
        )
    }
}
