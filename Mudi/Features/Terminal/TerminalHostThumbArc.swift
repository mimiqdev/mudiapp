import UIKit

/// Same overlay/actions as SwiftTerm, with an engine-neutral target.
@MainActor
final class TerminalHostThumbArcController: NSObject, UIGestureRecognizerDelegate {
    private weak var host: (any TerminalHost)?
    private let overlay = MudiThumbArcOverlay()
    init(host: any TerminalHost) {
        self.host = host
        super.init()
        let gesture = UILongPressGestureRecognizer(target: self, action: #selector(handle(_:)))
        gesture.numberOfTapsRequired = 1
        gesture.minimumPressDuration = 0.08
        gesture.allowableMovement = 20
        gesture.delegate = self
        host.hostView.addGestureRecognizer(gesture)
    }
    func cancel() { overlay.cancel() }
    @objc private func handle(_ gesture: UILongPressGestureRecognizer) {
        guard let host, host.isInputFocusAllowed, let container = host.hostView.superview else { cancel(); return }
        let point = gesture.location(in: container)
        switch gesture.state {
        case .began:
            guard !host.thumbArcPreferences.actions.isEmpty else { return }
            host.shortcutBar?.activePopup = .none
            host.shortcutBar?.clearModifiers()
            overlay.frame = host.hostView.frame
            container.addSubview(overlay)
            overlay.begin(origin: overlay.convert(point, from: container), preferences: host.thumbArcPreferences)
        case .changed: overlay.select(at: overlay.convert(point, from: container))
        case .ended:
            overlay.select(at: overlay.convert(point, from: container))
            if let action = overlay.finish() { host.executeThumbArcAction(action) }
        case .cancelled, .failed: cancel()
        default: break
        }
    }
}

/// Foundation block observers retain their token; release must explicitly
/// unregister it even when a hidden renderer was never started.
final class TerminalNotificationToken: @unchecked Sendable {
    private let token: NSObjectProtocol
    init(_ token: NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}
