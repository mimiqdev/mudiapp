import UIKit

/// Capsule geometry application for MudiTerminalShortcutBar: resolves the
/// capsule policy from the bar's horizontal size class and installs the
/// width/centering constraints. Compact (iPhone) expands to nearly the
/// full width with small margins; regular (iPad) centers a content-capped
/// capsule.
@MainActor
extension MudiTerminalShortcutBar {
    func applyCapsuleLayoutIfPossible() {
        guard let container = superview, container.bounds.width > 0 else {
            return
        }
        applyCapsuleLayout(
            MudiShortcutBarCapsulePolicy.resolved(for: traitCollection),
            in: container
        )
    }

    /// Same-class width changes can flip the capsule between the centered
    /// capped mode and the margin-span fallback (e.g. an iPad split view
    /// widened past the cap threshold); re-evaluate on bounds changes and
    /// rewrite the constraints only when the mode actually flips.
    func refreshCapsuleModeForBoundsChange() {
        guard let container = superview, container.bounds.width > 0 else {
            return
        }
        let policy = MudiShortcutBarCapsulePolicy.resolved(for: traitCollection)
        let layout = policy.capsuleLayout(
            containerWidth: container.bounds.width,
            barHeight: ShellTerminalView.shortcutBarHeight
        )
        guard layout.centered != lastAppliedCapsuleCentered else { return }
        applyCapsuleLayout(policy, in: container)
    }

    func applyCapsuleLayout(
        _ policy: MudiShortcutBarCapsulePolicy,
        in container: UIView
    ) {
        capsulePolicy = policy
        let layout = policy.capsuleLayout(
            containerWidth: container.bounds.width,
            barHeight: ShellTerminalView.shortcutBarHeight
        )
        lastAppliedCapsuleCentered = layout.centered

        capsuleLeadingConstraint?.isActive = false
        capsuleTrailingConstraint?.isActive = false
        capsuleCenterXConstraint?.isActive = false
        capsuleWidthConstraint?.isActive = false

        // Margins are always required so the capsule can never touch the
        // screen edges.
        let leading = leadingAnchor.constraint(
            greaterThanOrEqualTo: container.leadingAnchor,
            constant: layout.horizontalMargin
        )
        let trailing = trailingAnchor.constraint(
            lessThanOrEqualTo: container.trailingAnchor,
            constant: -layout.horizontalMargin
        )
        capsuleLeadingConstraint = leading
        capsuleTrailingConstraint = trailing
        var constraints: [NSLayoutConstraint] = [leading, trailing]

        if layout.centered {
            // Content-capped capsule: centered with a hard width cap
            // (yieldable so narrow regular-width layouts degrade to the
            // margins instead of breaking constraints).
            let centerX = centerXAnchor.constraint(
                equalTo: container.centerXAnchor
            )
            let width = widthAnchor.constraint(
                equalToConstant: layout.width
            )
            width.priority = UILayoutPriority.defaultHigh
            capsuleCenterXConstraint = centerX
            capsuleWidthConstraint = width
            constraints.append(contentsOf: [centerX, width])
        } else {
            // Expand to nearly the full width: equalities with margins.
            let leadingEquation = leadingAnchor.constraint(
                equalTo: container.leadingAnchor,
                constant: layout.horizontalMargin
            )
            let trailingEquation = trailingAnchor.constraint(
                equalTo: container.trailingAnchor,
                constant: -layout.horizontalMargin
            )
            capsuleLeadingConstraint = leadingEquation
            capsuleTrailingConstraint = trailingEquation
            constraints.append(contentsOf: [leadingEquation, trailingEquation])
        }

        NSLayoutConstraint.activate(constraints)
    }
}
