import Foundation

/// The app-wide color-scheme choice. System is deliberately the first case
/// and the default so a fresh install follows the device appearance.
enum AppearancePreference: String, CaseIterable, Codable, Equatable, Sendable {
    case system
    case light
    case dark
}

struct TerminalPreferences: Codable, Equatable, Sendable {
    var appearance: AppearancePreference
    var themeSelection: TerminalThemeSelection
    var fontFamily: String
    var fontSize: Double
    /// Whether the first-launch local-network onboarding already ran. Once
    /// set, later launches open the Host list without touching the system
    /// permission surface again.
    var hasCompletedLocalNetworkOnboarding: Bool

    init(
        appearance: AppearancePreference = .system,
        themeSelection: TerminalThemeSelection = TerminalThemeRegistry.defaultSelection,
        fontFamily: String = "JetBrainsMono Nerd Font Mono",
        fontSize: Double = 14,
        hasCompletedLocalNetworkOnboarding: Bool = false
    ) {
        self.appearance = appearance
        self.themeSelection = themeSelection
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.hasCompletedLocalNetworkOnboarding = hasCompletedLocalNetworkOnboarding
    }

    /// Source-compatible initializer for callers that only know the original
    /// appearance and size preference fields.
    init(
        appearance: AppearancePreference,
        fontSize: Double,
        hasCompletedLocalNetworkOnboarding: Bool = false
    ) {
        self.init(
            appearance: appearance,
            fontSize: fontSize,
            hasCompletedLocalNetworkOnboarding: hasCompletedLocalNetworkOnboarding
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appearance = try container.decodeIfPresent(
            AppearancePreference.self,
            forKey: .appearance
        ) ?? .system
        themeSelection = try container.decodeIfPresent(
            TerminalThemeSelection.self,
            forKey: .themeSelection
        ) ?? TerminalThemeRegistry.defaultSelection
        fontFamily = try container.decodeIfPresent(
            String.self,
            forKey: .fontFamily
        ) ?? "JetBrainsMono Nerd Font Mono"
        fontSize = try container.decodeIfPresent(
            Double.self,
            forKey: .fontSize
        ) ?? 14
        hasCompletedLocalNetworkOnboarding = try container.decodeIfPresent(
            Bool.self,
            forKey: .hasCompletedLocalNetworkOnboarding
        ) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case appearance
        case themeSelection
        case fontFamily
        case fontSize
        case hasCompletedLocalNetworkOnboarding
    }
}

protocol PreferencesStore: Sendable {
    func load() async throws -> TerminalPreferences
    func save(_ preferences: TerminalPreferences) async throws
}

enum PreferencesStoreError: Error, Equatable, LocalizedError, Sendable {
    case malformedValue

    var errorDescription: String? {
        switch self {
        case .malformedValue:
            "Saved terminal preferences are invalid."
        }
    }
}

/// Persists non-sensitive appearance and terminal display settings in the
/// app's UserDefaults domain. Credentials never pass through this store.
actor UserDefaultsPreferencesStore: PreferencesStore {
    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = "dev.mudi.mobile.terminal-preferences"
    ) {
        self.defaults = defaults
        self.key = key
    }

    func load() async throws -> TerminalPreferences {
        guard let data = defaults.data(forKey: key) else {
            return TerminalPreferences()
        }
        do {
            return try JSONDecoder().decode(TerminalPreferences.self, from: data)
        } catch {
            throw PreferencesStoreError.malformedValue
        }
    }

    func save(_ preferences: TerminalPreferences) async throws {
        let data = try JSONEncoder().encode(preferences)
        defaults.set(data, forKey: key)
    }
}
