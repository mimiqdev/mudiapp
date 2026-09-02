import UIKit

/// IME composition strip for MudiTerminalShortcutBar: the marked-text pill
/// inside the button row. iPad suppresses presentation entirely (hardware
/// keyboard is the norm); composition must never permanently alter the row
/// layout - spacing is restored whenever the strip hides.
@MainActor
extension MudiTerminalShortcutBar {
    func updateComposition(markedText: String?) {
        // Two independent concerns:
        // - Layout behavior (row controls hide while composing) is
        //   idiom-INDEPENDENT: an iPad floating software keyboard can
        //   still produce marked text.
        // - The visible marked-text pill is idiom-gated: iPad hosts no
        //   composition text presentation (hardware keyboard is the norm).
        let hasMarkedText = markedText?.isEmpty == false
        let text = isCompositionStripSuppressed
            ? nil
            : (hasMarkedText ? markedText : nil)
        let wasShowingComposition = isShowingComposition
        let shouldShowComposition = hasMarkedText

        isShowingComposition = shouldShowComposition
        compositionLabel.text = text
        compositionLabel.isHidden = isCompositionStripSuppressed
            || !shouldShowComposition
        compositionLabel.accessibilityLabel = text.map { "Composing \($0)" }
        shortcutButtons.forEach { $0.isHidden = shouldShowComposition }
        // IME feedback must not leave a lone full-width-looking control in
        // the row: the keyboard toggle joins the hidden set while composing.
        dismissKeyboardButton.isHidden = shouldShowComposition

        if !shouldShowComposition {
            // Composition must never permanently alter the row: restore the
            // fixed, uniform inter-item spacing exactly as at first layout.
            stackView.spacing = Self.rowSpacing
        }

        if shouldShowComposition != wasShowingComposition {
            invalidateIntrinsicContentSize()
        }
    }

    func addCompositionLabel() {
        compositionLabel.translatesAutoresizingMaskIntoConstraints = false
        compositionLabel.font = UIFont.monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize,
            weight: .regular
        )
        compositionLabel.adjustsFontForContentSizeCategory = true
        compositionLabel.numberOfLines = 1
        compositionLabel.lineBreakMode = .byClipping
        compositionLabel.textAlignment = .left
        compositionLabel.isHidden = true
        compositionLabel.accessibilityIdentifier = "terminal-ime-composition"
        compositionLabel.accessibilityTraits = [.staticText]
        compositionLabel.setContentHuggingPriority(.required, for: .horizontal)
        // Yieldable resistance: an extreme marked-text string clips instead
        // of fighting the row's required constraints.
        compositionLabel.setContentCompressionResistancePriority(
            .defaultHigh,
            for: .horizontal
        )
        compositionLabel.heightAnchor.constraint(equalToConstant: 32).isActive = true
        stackView.addArrangedSubview(compositionLabel)
    }
}
