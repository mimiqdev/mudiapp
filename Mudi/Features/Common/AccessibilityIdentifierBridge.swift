import SwiftUI
import UIKit

/// Installs a real UIView carrying an accessibility identifier into the
/// SwiftUI hierarchy so UIKit-side queries (tests, automation, Appium-style
/// tooling) can find and activate SwiftUI-only surfaces. Pure SwiftUI views
/// never materialize as UIViews, so contract-relevant identifiers are also
/// bridged here.
///
/// Marker bridges are inert 1x1 views. Control bridges are tiny UIControls
/// that forward activation to the same handler as the visible control.
struct AccessibilityIdentifierBridge: UIViewRepresentable {
    let identifier: String
    var action: (() -> Void)?

    func makeUIView(context: Context) -> UIView {
        if let action {
            let control = BridgeControl()
            control.accessibilityIdentifier = identifier
            control.onActivated = action
            return control
        }
        let view = UIView()
        view.accessibilityIdentifier = identifier
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        uiView.accessibilityIdentifier = identifier
        (uiView as? BridgeControl)?.onActivated = action
    }

    private final class BridgeControl: UIControl {
        var onActivated: (() -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            addTarget(
                self,
                action: #selector(activated),
                for: .touchUpInside
            )
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        @objc private func activated() {
            onActivated?()
        }
    }
}
