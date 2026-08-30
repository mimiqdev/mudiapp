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
    var fontSize: Double

    init(
        appearance: AppearancePreference = .system,
        fontSize: Double = 14
    ) {
        self.appearance = appearance
        self.fontSize = fontSize
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
