import SwiftUI

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

            Section("Terminal") {
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
            }
        }
        .navigationTitle("Settings")
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
