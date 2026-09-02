import UIKit

/// Keeps the shortcut bar pinned to the bottom of the terminal's container
/// so it stays visible even with the keyboard dismissed. While the keyboard
/// is up the bar rides above the keyboard frame, preserving the old
/// input-accessory ergonomics without tying the bar to first-responder
/// state.
@MainActor
extension ShellTerminalView {
    static let shortcutBarHeight: CGFloat = 44

    /// Pure geometry for the visible grid rows when a bottom strip is
    /// reserved for the shortcut bar. Same floor math as SwiftTerm's own
    /// row sizing, so the reserved strip removes exactly the rows that
    /// would otherwise render underneath the bar.
    static func visibleTerminalRows(
        containerHeight: CGFloat,
        reservedBottom: CGFloat,
        cellHeight: CGFloat
    ) -> Int {
        guard containerHeight > 0, containerHeight.isFinite,
              cellHeight > 0, cellHeight.isFinite,
              reservedBottom >= 0, reservedBottom.isFinite
        else { return 0 }
        let usableHeight = containerHeight - reservedBottom
        guard usableHeight > 0 else { return 0 }
        return Int(usableHeight / cellHeight)
    }

    func ensureShortcutBarAttached() {
        guard window != nil, let container = superview else { return }
        guard let bar = shortcutBar else { return }
        guard bar.superview === container,
              shortcutBarBottomConstraint != nil
        else {
            installShortcutBar(in: container)
            return
        }
    }

    func updateShortcutBarOffset(
        keyboardFrameEnd: CGRect? = nil,
        animationDuration: TimeInterval = 0,
        animationCurve: UInt = 0
    ) {
        guard let bar = shortcutBar,
              let container = bar.superview,
              let bottom = shortcutBarBottomConstraint
        else { return }
        let offset = shortcutBarOffset(
            in: container,
            keyboardFrameEnd: keyboardFrameEnd
        )
        let newConstant = -offset
        // The terminal scroll view reserves the whole strip between its own
        // bottom edge and the bar's TOP edge, so its grid rows always end
        // above the bar (keyboard up and down).
        let reserved = offset + Self.shortcutBarHeight
        if let chromeView = container as? TerminalChromeView {
            chromeView.setReservedBottom(reserved)
        }
        guard abs(bottom.constant - newConstant) > 0.25 else { return }
        bottom.constant = newConstant
        applyOffsetChange(
            to: container,
            duration: animationDuration,
            curve: animationCurve
        )
    }

    @objc func keyboardFrameWillChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo else { return }
        let endFrame = userInfo[UIResponder.keyboardFrameEndUserInfoKey]
            as? CGRect
        lastKeyboardFrameEnd = endFrame
        guard let endFrame else { return }
        updateShortcutBarOffset(
            keyboardFrameEnd: endFrame,
            animationDuration: userInfo[
                UIResponder.keyboardAnimationDurationUserInfoKey
            ] as? TimeInterval ?? 0,
            animationCurve: userInfo[
                UIResponder.keyboardAnimationCurveUserInfoKey
            ] as? UInt ?? 0
        )
    }

    func installKeyboardFrameObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardFrameWillChange(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
    }

    private func installShortcutBar(in container: UIView) {
        guard let bar = shortcutBar else { return }
        bar.removeFromSuperview()
        shortcutBarBottomConstraint = nil
        container.addSubview(bar)
        bar.translatesAutoresizingMaskIntoConstraints = false
        let bottomConstraint = bar.bottomAnchor.constraint(
            equalTo: container.bottomAnchor
        )
        shortcutBarBottomConstraint = bottomConstraint
        NSLayoutConstraint.activate([
            bottomConstraint,
            bar.heightAnchor.constraint(
                equalToConstant: Self.shortcutBarHeight
            )
        ])
        bar.applyCapsuleLayout(
            MudiShortcutBarCapsulePolicy.resolved(for: bar.traitCollection),
            in: container
        )

        // No scroll inset is needed for occlusion: the chrome reserves the
        // bar strip by shrinking the terminal view's frame (see
        // updateShortcutBarOffset), so SwiftTerm's grid rows end above the
        // bar and the resize carries the true visible rows.
        updateShortcutBarOffset()
    }

    private func shortcutBarOffset(
        in container: UIView,
        keyboardFrameEnd: CGRect?
    ) -> CGFloat {
        var offset = container.safeAreaInsets.bottom
            + (shortcutBar?.capsulePolicy?.bottomMargin ?? 0)
        if let window = container.window,
           let keyboardFrame = keyboardFrameEnd ?? lastKeyboardFrameEnd {
            let keyboardTop = container.convert(keyboardFrame, from: nil).minY
            if keyboardTop < container.bounds.maxY - 0.5 {
                offset = max(0, container.bounds.maxY - keyboardTop)
            }
        }
        return offset
    }

    private func applyOffsetChange(
        to container: UIView,
        duration: TimeInterval,
        curve: UInt
    ) {
        guard duration > 0 else {
            container.layoutIfNeeded()
            return
        }
        let options = UIView.AnimationOptions(rawValue: curve << 16)
            .union(.beginFromCurrentState)
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: options
        ) {
            container.layoutIfNeeded()
        }
    }
}
