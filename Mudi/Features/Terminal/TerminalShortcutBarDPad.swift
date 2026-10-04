import UIKit

@MainActor
extension MudiTerminalShortcutBar {
    private var dpadSafeBounds: CGRect {
        if let container = superview {
            var rect = convert(container.safeAreaLayoutGuide.layoutFrame, from: container)
            rect.size.height = max(0, min(rect.maxY, -8) - rect.minY)
            return rect
        }
        let height = max(terminalView?.bounds.height ?? 0, 222)
        return CGRect(x: 0, y: -height, width: bounds.width, height: height - 8)
    }
    @objc func handleDPadDrag(_ gesture: UIPanGestureRecognizer) {
        dpadOverlay.isDragging = gesture.state == .began || gesture.state == .changed
        guard gesture.state == .changed, !dpadOverlay.isLocked else { return }
        moveDPadOverlay(translation: gesture.translation(in: self))
        gesture.setTranslation(.zero, in: self)
        layoutIfNeeded()
    }
    func anchorDPadNearDirectionButton() {
        guard let leading = dpadLeadingConstraint, let bottom = dpadBottomConstraint else { return }
        let trigger = composer?.isHidden == false ? dpadAnchorView : dpadButton
        leading.constant = trigger.map { $0.convert($0.bounds, to: self).minX } ?? 8
        bottom.constant = -8
        clampDPadOverlayPosition(adding: .zero)
    }
    func reclampDPadAfterBoundsChange() {
        let safe = dpadSafeBounds
        let maxHeight = max(52, safe.height - 16)
        let heightChanged = dpadOverlay.setMaximumHeight(maxHeight)
        guard safe != lastDPadSafeBounds || heightChanged else { return }
        lastDPadSafeBounds = safe
        dpadOverlay.layoutIfNeeded()
        if let position = dpadRelativePosition, let leading = dpadLeadingConstraint, let bottom = dpadBottomConstraint {
            let size = CGSize(width: 150, height: min(206, maxHeight))
            let minX = safe.minX + 8, maxX = max(minX, safe.maxX - size.width - 8)
            let minY = safe.minY + 8, maxY = max(minY, safe.maxY - size.height)
            leading.constant = minX + position.x * (maxX - minX)
            bottom.constant = minY + position.y * (maxY - minY) + size.height
        } else {
            clampDPadOverlayPosition(adding: .zero, save: false)
        }
    }
    func moveDPadOverlay(translation: CGPoint) {
        guard !dpadOverlay.isLocked, bounds.width > 0 else { return }
        clampDPadOverlayPosition(adding: translation)
    }
    func clampDPadOverlayPosition(adding translation: CGPoint, save: Bool = true) {
        guard let leading = dpadLeadingConstraint, let bottom = dpadBottomConstraint, bounds.width > 0 else { return }
        let safe = dpadSafeBounds
        let height = min(206, max(52, safe.height - 16))
        let minX = safe.minX + 8, maxX = max(minX, safe.maxX - 150 - 8)
        let minY = safe.minY + 8, maxY = max(minY, safe.maxY - height)
        let x = min(max(leading.constant + translation.x, minX), maxX)
        let y = min(max(bottom.constant - height + translation.y, minY), maxY)
        leading.constant = x; bottom.constant = y + height
        if save {
            let normalized = CGPoint(x: maxX > minX ? (x - minX) / (maxX - minX) : 0,
                                     y: maxY > minY ? (y - minY) / (maxY - minY) : 1)
            dpadRelativePosition = normalized
            UserDefaults.standard.set([Double(normalized.x), Double(normalized.y)], forKey: "dev.mudi.mobile.dpad-relative-position")
        }
        setNeedsLayout()
    }
}
