import UIKit

/// Floating D-pad card positioning for MudiTerminalShortcutBar: popover
/// anchoring above the direction button, drag-to-reposition, and re-clamping
/// when the bar's bounds change.
@MainActor
extension MudiTerminalShortcutBar {
    @objc func handleDPadDrag(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .changed else { return }
        moveDPadOverlay(translation: gesture.translation(in: self))
        gesture.setTranslation(.zero, in: self)
        // Track the finger immediately instead of a frame late.
        layoutIfNeeded()
    }

    /// Pops the D-pad card up just above the shortcut bar, horizontally
    /// aligned with the direction button, like a popover from the bar.
    func anchorDPadNearDirectionButton() {
        guard let dpadLeadingConstraint,
              let dpadBottomConstraint,
              let dpadButton,
              bounds.width > 0
        else { return }
        let width = max(dpadOverlay.bounds.width, 1)
        let leadingRange = max(bounds.width - width - 16, 0)
        dpadLeadingConstraint.constant = min(
            max(dpadButton.frame.minX - 8, 8),
            8 + leadingRange
        )
        dpadBottomConstraint.constant = -12
        // Constant mutations need an explicit invalidation to reach the
        // next layout pass; flush immediately so the card pops in place.
        setNeedsLayout()
        layoutIfNeeded()
    }

    func reclampDPadAfterBoundsChange() {
        // A width change (rotation, split view) can leave a stored drag
        // offset that fights the required trailing cap; re-clamp so the
        // position always satisfies the current bounds. Invoked from the
        // bar's own layoutSubviews (single override site).
        clampDPadOverlayPosition(adding: .zero)
    }

    func moveDPadOverlay(translation: CGPoint) {
        guard bounds.width > 0 else { return }
        clampDPadOverlayPosition(adding: translation)
    }

    func clampDPadOverlayPosition(adding translation: CGPoint) {
        guard let dpadLeadingConstraint,
              let dpadBottomConstraint,
              bounds.width > 0
        else { return }
        let width = max(dpadOverlay.bounds.width, 1)
        let leadingRange = max(bounds.width - width - 16, 0)
        let newLeading = min(
            max(dpadLeadingConstraint.constant + translation.x, 8),
            8 + leadingRange
        )
        let newBottom = min(
            max(dpadBottomConstraint.constant + translation.y, -480),
            -12
        )
        var needsLayout = false
        if abs(newLeading - dpadLeadingConstraint.constant) > 0.01 {
            dpadLeadingConstraint.constant = newLeading
            needsLayout = true
        }
        if abs(newBottom - dpadBottomConstraint.constant) > 0.01 {
            dpadBottomConstraint.constant = newBottom
            needsLayout = true
        }
        // Constraint constant mutations do not flush on their own in every
        // context; flag the bar so the next pass always picks them up.
        if needsLayout {
            setNeedsLayout()
        }
    }
}
