import UIKit

/// Geometry policy for the floating shortcut-bar capsule: horizontal
/// margins, floating gap above the bottom edge, and a content-capped
/// maximum width (iPad centers a capped capsule; iPhone expands to nearly
/// the full width). Pure and fully testable - the bar only applies the
/// resolved layout.
struct MudiShortcutBarCapsulePolicy: Equatable {
    let horizontalMargin: CGFloat
    let bottomMargin: CGFloat
    let maxContentWidth: CGFloat

    /// iPhone (compact width): the capsule expands to nearly the full
    /// screen width with small horizontal margins.
    static let phone = Self(
        horizontalMargin: 12,
        bottomMargin: 10,
        maxContentWidth: .greatestFiniteMagnitude
    )

    /// iPad (regular width): the capsule stays centered with a
    /// content-capped width instead of spanning the display.
    static let pad = Self(
        horizontalMargin: 12,
        bottomMargin: 10,
        maxContentWidth: 460
    )

    /// Resolves the policy from the bar's horizontal size class.
    static func resolved(
        for traits: UITraitCollection
    ) -> MudiShortcutBarCapsulePolicy {
        traits.horizontalSizeClass == .regular ? .pad : .phone
    }

    /// Resolves the concrete capsule geometry for a container width:
    /// the capsule never spans wider than the margins allow and never
    /// exceeds the content cap; corners are fully rounded (half the bar
    /// height).
    func capsuleLayout(
        containerWidth: CGFloat,
        barHeight: CGFloat
    ) -> MudiShortcutBarCapsuleLayout {
        let maxSpan = max(containerWidth - 2 * horizontalMargin, 0)
        let width = min(maxSpan, maxContentWidth)
        // The capsule centers itself exactly when the content cap (not the
        // margins) is the binding constraint.
        let centered = maxContentWidth < maxSpan
        return MudiShortcutBarCapsuleLayout(
            horizontalMargin: horizontalMargin,
            bottomMargin: bottomMargin,
            width: width,
            cornerRadius: barHeight / 2,
            centered: centered
        )
    }
}

/// The resolved capsule geometry produced by
/// `MudiShortcutBarCapsulePolicy.capsuleLayout(containerWidth:barHeight:)`.
struct MudiShortcutBarCapsuleLayout: Equatable {
    let horizontalMargin: CGFloat
    let bottomMargin: CGFloat
    let width: CGFloat
    let cornerRadius: CGFloat
    let centered: Bool
}
