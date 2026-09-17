import HerdrKit
@preconcurrency import SwiftTerm
import UIKit

@MainActor
extension ShellTerminalView {
    func loadRemoteScrollCapability(
        for session: SSHShellSession,
        identity: ObjectIdentifier
    ) {
        remoteScrollCapabilityTask?.cancel()
        remoteScrollCapabilityTask = Task { [weak self, session, identity] in
            let capability = await session.scrollCapability()
            guard !Task.isCancelled else { return }
            guard let self, self.sessionIdentity == identity else { return }
            self.setRemoteScrollCapability(capability)
        }
    }

    /// Applies the session's remote scroll path.
    ///
    /// `hostScrollback` asks Herdr for full `terminal.frame` snapshots through
    /// `session.scroll`. `remoteMouseWheel` instead forwards encoded wheel
    /// events to the remote application, because a raw Mosh attach has no
    /// host-side scrollback and its replacement frames never accumulate local
    /// history. Either way the local (empty) scrollback must not own the
    /// gesture.
    private func setRemoteScrollCapability(_ capability: TerminalScrollCapability) {
        remoteScrollbackEnabled = capability == .hostScrollback
        remoteMouseWheelEnabled = capability == .remoteMouseWheel
        guard remoteScrollbackEnabled || remoteMouseWheelEnabled else {
            if let remoteScrollGesture {
                removeGestureRecognizer(remoteScrollGesture)
            }
            remoteScrollGesture = nil
            isScrollEnabled = true
            return
        }

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
        isScrollEnabled = false
    }

    @objc private func handleRemoteScrollPan(_ gesture: UIPanGestureRecognizer) {
        handleRemoteScroll(
            state: gesture.state,
            translationY: gesture.translation(in: self).y,
            velocityY: gesture.velocity(in: self).y,
            location: gesture.location(in: self)
        )
    }

    /// Testable core of ``handleRemoteScrollPan(_:)``. UIKit owns
    /// `UIPanGestureRecognizer.state`, so tests drive the routing here instead
    /// of through a live touch sequence.
    func handleRemoteScroll(
        state: UIGestureRecognizer.State,
        translationY: CGFloat,
        velocityY: CGFloat,
        location: CGPoint
    ) {
        guard remoteScrollbackEnabled || remoteMouseWheelEnabled else { return }

        switch state {
        case .began:
            remoteScrollInertiaTask?.cancel()
            remoteScrollInertiaTask = nil
            remoteScrollLastTranslation = translationY
            remoteScrollDistance = 0
            remoteScrollLocation = location
        case .changed:
            let delta = translationY - remoteScrollLastTranslation
            remoteScrollLastTranslation = translationY
            // Natural scrolling: content follows the finger. Drag down to
            // reveal history above (Herdr terminal.scroll up / wheel up).
            remoteScrollDistance += delta
            remoteScrollLocation = location
            flushRemoteScrollDistance()
        case .ended:
            remoteScrollLocation = location
            remoteScrollLastTranslation = 0
            startRemoteScrollInertia(velocityY: velocityY)
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
                guard let self, self.remoteScrollbackEnabled
                        || self.remoteMouseWheelEnabled
                else { return }
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
        requestRemoteScroll(
            direction: scrollingUp ? .up : .down,
            lines: lines
        )
    }

    /// Routes a whole-line scroll request to the session's remote scroll path.
    private func requestRemoteScroll(
        direction: TerminalScrollDirection,
        lines: Int
    ) {
        if remoteScrollbackEnabled {
            enqueueRemoteScroll(direction: direction, lines: lines)
        } else if remoteMouseWheelEnabled {
            sendRemoteMouseWheel(
                direction: direction,
                lines: lines,
                location: remoteScrollLocation ?? CGPoint(
                    x: bounds.midX,
                    y: bounds.midY
                )
            )
        }
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

    /// Forwards a vertical pan to a directly attached application as terminal
    /// mouse-wheel events.
    ///
    /// SwiftTerm owns the wire encoding (`1006` SGR, `1005` UTF-8, `1015`
    /// urxvt, or the legacy `CSI M` form) and the remote application owns the
    /// viewport, so the events are emitted through the terminal instead of
    /// synthesizing bytes here. No events are produced while the application
    /// has mouse reporting off: its mouse protocol would surface the sequence
    /// as literal escape input.
    private func sendRemoteMouseWheel(
        direction: TerminalScrollDirection,
        lines: Int,
        location: CGPoint
    ) {
        guard remoteMouseWheelEnabled, lines > 0 else { return }
        let terminal = getTerminal()
        guard terminal.mouseMode != .off else { return }

        let position = remoteMousePosition(forGridLocation: location)
        let button = direction == .up
            ? Self.mouseWheelUpButton
            : Self.mouseWheelDownButton
        // One event per line keeps the finger 1:1 with the app's scroll step,
        // like the host scrollback path. The cap only bounds a pathological
        // single flush (for example a 1000-point jump) so it cannot enqueue an
        // unbounded burst of sends.
        let eventCount = min(lines, Self.maximumRemoteWheelEventsPerFlush)
        for _ in 0..<eventCount {
            terminal.sendEvent(
                buttonFlags: button,
                x: position.column,
                y: position.row,
                pixelX: position.pixelColumn,
                pixelY: position.pixelRow
            )
        }
    }

    /// Converts a touch point to the grid cell SwiftTerm's mouse encoder
    /// expects. Coordinates follow the rendered grid, including any content
    /// offset left by a pre-capability local scroll.
    private func remoteMousePosition(
        forGridLocation location: CGPoint
    ) -> RemoteMousePosition {
        let terminal = getTerminal()
        let columns = max(terminal.cols, 1)
        let rows = max(terminal.rows, 1)
        let frame = getOptimalFrameSize()
        let cellWidth = max(frame.width / CGFloat(columns), 1)
        let cellHeight = max(frame.height / CGFloat(rows), 1)
        let point = CGPoint(
            x: location.x + contentOffset.x,
            y: location.y + contentOffset.y
        )
        return RemoteMousePosition(
            column: min(max(Int(point.x / cellWidth), 0), columns - 1),
            row: min(max(Int(point.y / cellHeight), 0), rows - 1),
            pixelColumn: Int(point.x * contentScaleFactor),
            pixelRow: Int(point.y * contentScaleFactor)
        )
    }

    private static let mouseWheelUpButton = 64
    private static let mouseWheelDownButton = 65
    private static let maximumRemoteWheelEventsPerFlush = 64

    override func accessibilityScroll(
        _ direction: UIAccessibilityScrollDirection
    ) -> Bool {
        guard remoteScrollbackEnabled || remoteMouseWheelEnabled else {
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

        requestRemoteScroll(
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
        guard remoteScrollbackEnabled || remoteMouseWheelEnabled else {
            super.pressesBegan(presses, with: event)
            return
        }

        var remainingPresses = Set<UIPress>()
        var handledPage = false
        for press in presses {
            switch press.key?.keyCode {
            case .keyboardPageUp:
                requestRemoteScroll(
                    direction: .up,
                    lines: max(getTerminal().rows, 1)
                )
                handledPage = true
            case .keyboardPageDown:
                requestRemoteScroll(
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
        guard remoteScrollbackEnabled || remoteMouseWheelEnabled,
              !hasActiveSelection,
              let panGesture = gestureRecognizer as? UIPanGestureRecognizer
        else { return false }
        // Wheel input only exists while the attached application reports mouse
        // input; otherwise let SwiftTerm's own pan (selection/cursor keys)
        // handle the touch instead of swallowing it.
        if remoteMouseWheelEnabled, getTerminal().mouseMode == .off {
            return false
        }
        let velocity = panGesture.velocity(in: self)
        return abs(velocity.y) > abs(velocity.x)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard remoteScrollbackEnabled || remoteMouseWheelEnabled,
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
        // Cursor-positioning taps coexist with SwiftTerm's own tap: their
        // responsibilities are disjoint (the positioning planner stays out
        // of SwiftTerm's context-menu band and mouse-reporting mode).
        if gestureRecognizer is UITapGestureRecognizer,
           otherGestureRecognizer is UITapGestureRecognizer {
            return true
        }
        // A vertical scroll must be owned by one recognizer, never duplicated
        // as terminal mouse motion and a remote history request.
        return false
    }
}

/// One grid and pixel position for SwiftTerm's mouse encoder. Kept out of
/// the gesture extension as a named type so the routing code does not carry
/// a four-element tuple.
private struct RemoteMousePosition {
    let column: Int
    let row: Int
    let pixelColumn: Int
    let pixelRow: Int
}
