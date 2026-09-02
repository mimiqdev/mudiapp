import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct SettingsView: View {
    @ObservedObject var model: RootViewModel
    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Color scheme", selection: Binding(
                    get: { model.preferences.appearance },
                    set: { model.updateAppearance($0) }
                )) {
                    ForEach(AppearancePreference.allCases, id: \.self) { appearance in
                        Text(appearance.label).tag(appearance)
                    }
                }
            }

            TerminalAppearanceSection(model: model)
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The shared terminal-only settings section used by both the Hosts Settings
/// page and the in-terminal settings sheet. Preferences always flow through
/// RootViewModel, so live terminal updates and persisted settings cannot drift.
@MainActor
struct TerminalAppearanceSection: View {
    @ObservedObject var model: RootViewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var isFontImporterPresented = false
    @State private var fontImportError: String?

    var body: some View {
        Section("Terminal") {
            Picker("Theme", selection: Binding(
                get: { model.preferences.themeSelection },
                set: { model.updateThemeSelection($0) }
            )) {
                ForEach(TerminalThemeRegistry.selectionOptions, id: \.self) { selection in
                    Text(TerminalThemeRegistry.label(for: selection))
                        .tag(selection)
                }
            }
            .accessibilityIdentifier("terminal-theme-picker")

            Picker("Font", selection: Binding(
                get: { model.preferences.fontFamily },
                set: { model.updateFontFamily($0) }
            )) {
                ForEach(TerminalFontRegistry.availableFamilyNames, id: \.self) { familyName in
                    Text(familyName).tag(familyName)
                }
            }
            .accessibilityIdentifier("terminal-font-picker")

            Button("Import Font…") {
                isFontImporterPresented = true
            }
            .accessibilityIdentifier("terminal-font-import")

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Font size")
                    Spacer()
                    Text("\(model.preferences.fontSize, specifier: "%.1f") pt")
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { model.preferences.fontSize },
                        set: { model.updateFontSize($0) }
                    ),
                    in: 10...32,
                    step: 0.5
                )
                .accessibilityLabel("Terminal font size")
            }

            TerminalPreviewView(
                theme: selectedTheme,
                fontFamily: model.preferences.fontFamily,
                fontSize: model.preferences.fontSize
            )
            .frame(minHeight: 150, maxHeight: 190)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier("terminal-theme-preview")

            // UIKit automation cannot rely on SwiftUI controls exposing
            // their identifiers as descendant UIViews. Keep one marker per
            // shared control contract while the controls themselves remain
            // the only visible stateful views.
            AccessibilityIdentifierBridge(identifier: "terminal-theme-picker")
                .frame(width: 1, height: 1)
            AccessibilityIdentifierBridge(identifier: "terminal-font-picker")
                .frame(width: 1, height: 1)
            AccessibilityIdentifierBridge(identifier: "terminal-font-import")
                .frame(width: 1, height: 1)
            AccessibilityIdentifierBridge(identifier: "terminal-theme-preview")
                .frame(width: 1, height: 1)
        }
        .fileImporter(
            isPresented: $isFontImporterPresented,
            allowedContentTypes: supportedFontTypes,
            allowsMultipleSelection: false,
            onCompletion: handleFontImport
        )
        .alert(
            "Font import failed",
            isPresented: Binding(
                get: { fontImportError != nil },
                set: { if !$0 { fontImportError = nil } }
            ),
            actions: { Button("OK", role: .cancel) {} },
            message: { Text(fontImportError ?? "The font could not be registered.") }
        )
    }

    private var selectedTheme: TerminalTheme {
        let variant: TerminalThemeVariant = colorScheme == .dark ? .dark : .light
        return TerminalThemeRegistry.resolve(
            model.preferences.themeSelection,
            for: variant
        ) ?? TerminalThemeRegistry.builtInThemes[0]
    }

    private var supportedFontTypes: [UTType] {
        TerminalFontRegistry.supportedFileExtensions.compactMap {
            UTType(filenameExtension: $0)
        }
    }

    private func handleFontImport(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first,
                  let familyName = TerminalFontRegistry.registerImportedFont(at: url)
            else {
                fontImportError = "Choose a valid TTF or OTF font."
                return
            }
            model.updateFontFamily(familyName)
        case let .failure(error):
            // Cancellation is a normal picker outcome, not an error banner.
            if (error as NSError).code != NSUserCancelledError {
                fontImportError = error.localizedDescription
            }
        }
    }
}

/// A compact sheet for changing terminal appearance without leaving an open
/// session. It intentionally embeds the same section and model as SettingsView.
@MainActor
struct TerminalAppearanceSettingsView: View {
    @ObservedObject var model: RootViewModel

    var body: some View {
        Form {
            TerminalAppearanceSection(model: model)
        }
        .navigationTitle("Terminal Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private extension AppearancePreference {
    var label: String {
        switch self {
        case .system:
            "System"
        case .light:
            "Light"
        case .dark:
            "Dark"
        }
    }
}
