import HerdrKit
@preconcurrency import SwiftTerm
import UIKit

@MainActor
extension ShellTerminalView {
    func loadRemoteScrollbackCapability(
        for session: SSHShellSession,
        identity: ObjectIdentifier
    ) {
        remoteScrollCapabilityTask?.cancel()
        remoteScrollCapabilityTask = Task { [weak self, session, identity] in
            let supported = await session.supportsRemoteScrollback()
            guard !Task.isCancelled else { return }
            guard let self, self.sessionIdentity == identity else { return }
            self.setRemoteScrollbackEnabled(supported)
        }
    }

    func pageUpFromShortcut() {
        if remoteScrollbackEnabled {
            enqueueRemoteScroll(
                direction: .up,
                lines: max(getTerminal().rows, 1)
            )
        } else {
            pageUp()
        }
    }

    func pageDownFromShortcut() {
        if remoteScrollbackEnabled {
            enqueueRemoteScroll(
                direction: .down,
                lines: max(getTerminal().rows, 1)
            )
        } else {
            pageDown()
        }
    }

    private func setRemoteScrollbackEnabled(_ enabled: Bool) {
        remoteScrollbackEnabled = enabled
        if enabled {
            if remoteScrollGesture == nil {
                let gesture = UIPanGestureRecognizer(
                    target: self,
                    action: #selector(handleRemoteScrollPan(_:))
                )
                gesture.delegate = self
                gesture.cancelsTouchesInView = false
                gesture.allowedScrollTypesMask = .all
                addGestureRecognizer(gesture)
                remoteScrollGesture = gesture
            }
            // Herdr owns the history for an attached pane. Let the gesture
            // request full terminal.frame snapshots instead of scrolling the
            // small local buffer that only contains frames seen since attach.
            isScrollEnabled = false
        } else {
            if let remoteScrollGesture {
                removeGestureRecognizer(remoteScrollGesture)
            }
            remoteScrollGesture = nil
            isScrollEnabled = true
        }
    }

    @objc private func handleRemoteScrollPan(_ gesture: UIPanGestureRecognizer) {
        guard remoteScrollbackEnabled else { return }

        switch gesture.state {
        case .began:
            remoteScrollInertiaTask?.cancel()
            remoteScrollInertiaTask = nil
            remoteScrollLastTranslation = gesture.translation(in: self).y
            remoteScrollDistance = 0
        case .changed:
            let translation = gesture.translation(in: self).y
            let delta = translation - remoteScrollLastTranslation
            remoteScrollLastTranslation = translation
            // Natural scrolling: content follows the finger. Drag down to
            // reveal history above (Herdr terminal.scroll up).
            remoteScrollDistance += delta
            flushRemoteScrollDistance()
        case .ended:
            let velocity = gesture.velocity(in: self).y
            remoteScrollLastTranslation = 0
            startRemoteScrollInertia(velocityY: velocity)
        case .cancelled, .failed:
            remoteScrollInertiaTask?.cancel()
            remoteScrollInertiaTask = nil
            remoteScrollDistance = 0
            remoteScrollLastTranslation = 0
        default:
            break
        }
    }

    private func startRemoteScrollInertia(velocityY: CGFloat) {
        remoteScrollInertiaTask?.cancel()
        // Slow drags stay 1:1 with the finger. Only a flick keeps moving.
        let flickThreshold: CGFloat = 320
        guard abs(velocityY) >= flickThreshold else {
            remoteScrollDistance = 0
            remoteScrollInertiaTask = nil
            return
        }

        remoteScrollInertiaTask = Task { [weak self] in
            var velocity = velocityY
            let frameNanoseconds: UInt64 = 16_000_000
            let dt = CGFloat(frameNanoseconds) / 1_000_000_000
            let deceleration: CGFloat = 2_400
            let stopSpeed: CGFloat = 140
            while !Task.isCancelled, abs(velocity) > stopSpeed {
                try? await Task.sleep(nanoseconds: frameNanoseconds)
                guard let self, self.remoteScrollbackEnabled else { return }
                self.remoteScrollDistance += velocity * dt
                self.flushRemoteScrollDistance()
                let sign: CGFloat = velocity > 0 ? 1 : -1
                velocity -= sign * deceleration * dt
                if velocity * sign <= 0 {
                    break
                }
            }
            self?.remoteScrollDistance = 0
        }
    }

    private func flushRemoteScrollDistance() {
        let lineHeight = max(font.lineHeight, 1)
        let lines = Int(abs(remoteScrollDistance) / lineHeight)
        guard lines > 0 else { return }

        let scrollingUp = remoteScrollDistance > 0
        let consumedDistance = CGFloat(lines) * lineHeight
        remoteScrollDistance += scrollingUp ? -consumedDistance : consumedDistance
        enqueueRemoteScroll(
            direction: scrollingUp ? .up : .down,
            lines: lines
        )
    }

    private func enqueueRemoteScroll(
        direction: TerminalScrollDirection,
        lines: Int
    ) {
        guard remoteScrollbackEnabled,
              lines > 0,
              let session,
              let identity = sessionIdentity
        else { return }

        let previousTask = remoteScrollTask
        remoteScrollTask = Task { [weak self, session, identity, previousTask] in
            await previousTask?.value
            guard !Task.isCancelled else { return }
            do {
                try await session.scroll(direction: direction, lines: lines)
            } catch {
                guard !Task.isCancelled,
                      let self,
                      self.sessionIdentity == identity
                else { return }
                self.report(error)
            }
        }
    }

    override func accessibilityScroll(
        _ direction: UIAccessibilityScrollDirection
    ) -> Bool {
        guard remoteScrollbackEnabled else {
            return super.accessibilityScroll(direction)
        }

        let scrollDirection: TerminalScrollDirection
        switch direction {
        case .up, .left, .previous:
            scrollDirection = .up
        case .down, .right, .next:
            scrollDirection = .down
        default:
            return false
        }

        enqueueRemoteScroll(
            direction: scrollDirection,
            lines: max(getTerminal().rows, 1)
        )
        UIAccessibility.post(notification: .pageScrolled, argument: nil)
        return true
    }

    override func pressesBegan(
        _ presses: Set<UIPress>,
        with event: UIPressesEvent?
    ) {
        guard remoteScrollbackEnabled else {
            super.pressesBegan(presses, with: event)
            return
        }

        var remainingPresses = Set<UIPress>()
        var handledPage = false
        for press in presses {
            switch press.key?.keyCode {
            case .keyboardPageUp:
                enqueueRemoteScroll(
                    direction: .up,
                    lines: max(getTerminal().rows, 1)
                )
                handledPage = true
            case .keyboardPageDown:
                enqueueRemoteScroll(
                    direction: .down,
                    lines: max(getTerminal().rows, 1)
                )
                handledPage = true
            default:
                remainingPresses.insert(press)
            }
        }

        if !handledPage || !remainingPresses.isEmpty {
            super.pressesBegan(remainingPresses, with: event)
        }
    }

    override func gestureRecognizerShouldBegin(
        _ gestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard gestureRecognizer === remoteScrollGesture else { return true }
        guard remoteScrollbackEnabled,
              !hasActiveSelection,
              let panGesture = gestureRecognizer as? UIPanGestureRecognizer
        else { return false }
        let velocity = panGesture.velocity(in: self)
        return abs(velocity.y) > abs(velocity.x)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard remoteScrollbackEnabled,
              gestureRecognizer === remoteScrollGesture,
              otherGestureRecognizer is UIPanGestureRecognizer,
              otherGestureRecognizer !== remoteScrollGesture
        else { return false }

        // SwiftTerm's mouse reporter is an internal UIPanGestureRecognizer. It
        // must wait for this vertical-pan decision; if ours rejects a
        // horizontal pan or an active selection, the competing pan can run.
        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // A vertical scroll must be owned by one recognizer, never duplicated
        // as terminal mouse motion and a remote history request.
        false
    }
}
