import UIKit

/// Geometry for the shortcut strip: iPhone uses the full bottom edge;
/// iPad centers a floating strip with a capped width.
struct MudiShortcutBarCapsulePolicy: Equatable {
    let horizontalMargin: CGFloat
    let bottomMargin: CGFloat
    let maxContentWidth: CGFloat

    /// iPhone (compact width): a flat strip spanning the bottom edge.
    static let phone = Self(
        horizontalMargin: 0,
        bottomMargin: 0,
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
    /// exceeds the content cap. The floating iPad strip uses a 12-point radius.
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
            cornerRadius: horizontalMargin == 0 ? 0 : 12,
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
