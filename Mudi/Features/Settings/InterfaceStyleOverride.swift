import SwiftUI
import UIKit

/// Applies an explicit user interface style to the hosting window.
///
/// SwiftUI's `preferredColorScheme(nil)` does not re-resolve traits on an
/// already-presented sheet, so switching Dark/Light→System left the open
/// Settings sheet stuck in the previous scheme. This bridge mirrors the
/// selected appearance onto `window.overrideUserInterfaceStyle`, which
/// updates synchronously: `.dark`/`.light` pin the style, `nil` restores
/// the system default.
struct InterfaceStyleOverride: UIViewRepresentable {
    let colorScheme: ColorScheme?

    func makeUIView(context: Context) -> UIView {
        OverrideUIView()
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard let overrideView = uiView as? OverrideUIView else { return }
        overrideView.desiredStyle = Self.uiStyle(for: colorScheme)
    }

    static func uiStyle(for colorScheme: ColorScheme?) -> UIUserInterfaceStyle {
        switch colorScheme {
        case .dark:
            .dark
        case .light:
            .light
        case nil:
            .unspecified
        @unknown default:
            .unspecified
        }
    }

    private final class OverrideUIView: UIView {
        var desiredStyle: UIUserInterfaceStyle = .unspecified {
            didSet {
                guard desiredStyle != oldValue else { return }
                applyOverride()
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            applyOverride()
        }

        private func applyOverride() {
            window?.overrideUserInterfaceStyle = desiredStyle
        }
    }
}
