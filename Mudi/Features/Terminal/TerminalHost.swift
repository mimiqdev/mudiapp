import HerdrKit
import UIKit

/// Engine-neutral UIKit/shortcut/session contract. This file defines the seam;
/// conformance is tested before either renderer is wired through it.
@MainActor
protocol TerminalHost: AnyObject {
    var hostView: UIView { get }
    var shortcutBar: MudiTerminalShortcutBar? { get }
    var controlModifier: Bool { get set }
    var metaModifier: Bool { get set }
    var isInputFocusAllowed: Bool { get }
    var isFirstResponder: Bool { get }
    var shouldRestoreInputFocus: Bool { get set }
    var onInputFocusChange: ((Bool) -> Void)? { get set }
    var onOpenPanePicker: (() -> Void)? { get set }
    var thumbArcPreferences: ThumbArcPreferences { get set }
    var lastKeyboardFrameEnd: CGRect? { get }
    var appliedTheme: TerminalTheme? { get }
    var session: SSHShellSession? { get }
    @discardableResult func becomeFirstResponder() -> Bool
    @discardableResult func resignFirstResponder() -> Bool
    func insertText(_ text: String)
    func send(_ bytes: [UInt8])
    func paste(_ sender: Any?)
    func sendCursorKey(normal: [UInt8], application: [UInt8], final: UInt8)
    func sendComposedText(_ text: String, bracketedPaste: Bool, appendReturn: Bool)
    func updateShortcutBarOffset(keyboardFrameEnd: CGRect?, animationDuration: TimeInterval, animationCurve: UInt)
    var isModifierFocusHandoff: Bool { get set }
    func updateInputFocus(isAllowed: Bool)
    func requestTerminalRelayout()
    func updateFont(familyName: String?, pointSize: Double)
    func apply(theme: TerminalTheme) throws
    func start(session: SSHShellSession, onError: @escaping (String) -> Void, onClosed: @escaping () -> Void)
    func updateSession(session: SSHShellSession, onError: @escaping (String) -> Void, onClosed: @escaping () -> Void)
    func stop()
}

extension TerminalHost {
    func updateShortcutBarOffset() {
        updateShortcutBarOffset(keyboardFrameEnd: nil, animationDuration: 0, animationCurve: 0)
    }
}
