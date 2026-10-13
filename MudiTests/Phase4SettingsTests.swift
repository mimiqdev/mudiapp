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

    func testLegacyAppearanceAndFontInitializerKeepsDefaultsWithoutRecursion() {
        let preferences = TerminalPreferences(
            appearance: .dark, fontSize: 19.5,
            hasCompletedLocalNetworkOnboarding: true,
            isDebugLoggingEnabled: true, isSaveLogsEnabled: true,
            isAddressPromotionEnabled: true
        )
        XCTAssertEqual(preferences.appearance, .dark)
        XCTAssertEqual(preferences.fontSize, 19.5)
        XCTAssertEqual(preferences.terminalEngine, .swiftTerm)
        XCTAssertEqual(preferences.themeSelection, TerminalThemeRegistry.defaultSelection)
        XCTAssertEqual(preferences.fontFamily, "JetBrainsMono Nerd Font Mono")
        XCTAssertTrue(preferences.hasCompletedLocalNetworkOnboarding)
        XCTAssertTrue(preferences.isDebugLoggingEnabled)
        XCTAssertTrue(preferences.isSaveLogsEnabled)
        XCTAssertTrue(preferences.isAddressPromotionEnabled)
    }

    func testTerminalFontSizeCanBeReadWrittenAndRestored() async throws {
        let store = makeStore()
        let saved = TerminalPreferences(fontSize: 19.5)

        try await store.save(saved)
        let loaded = try await store.load()

        XCTAssertEqual(loaded.fontSize, saved.fontSize, accuracy: 0.001)
    }

    private func makeStore() -> UserDefaultsPreferencesStore {
        let suiteName = "com.mimiqdev.phase4.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return UserDefaultsPreferencesStore(
            defaults: defaults,
            key: "terminal-preferences"
        )
    }
}
