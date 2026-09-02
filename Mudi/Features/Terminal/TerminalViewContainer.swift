import HerdrKit
@preconcurrency import SwiftTerm
import SwiftUI

/// UIKit container that hosts the terminal scroll view and reserves the
/// persistent shortcut-bar strip below it: the scroll view's bottom edge
/// sits above the bar, so SwiftTerm lays out grid rows only in the truly
/// visible region, `terminal.resize` receives the true visible rows, and
/// the bar can never cover content (keyboard up or down).
final class TerminalChromeView: UIView {
    private(set) var terminalView: ShellTerminalView!
    private var terminalBottomConstraint: NSLayoutConstraint!

    init(terminalView: ShellTerminalView) {
        super.init(frame: .zero)
        self.terminalView = terminalView
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminalView)
        terminalBottomConstraint = terminalView.bottomAnchor.constraint(
            equalTo: bottomAnchor
        )
        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: topAnchor),
            terminalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalBottomConstraint,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Reserves `height` points above the chrome's bottom edge for the
    /// shortcut-bar strip (its riding offset plus the bar height). The
    /// terminal scroll view shrinks accordingly, so its grid rows always
    /// end above the bar.
    func setReservedBottom(_ height: CGFloat) {
        let constant = -max(height, 0)
        guard abs(terminalBottomConstraint.constant - constant) > 0.25
        else { return }
        terminalBottomConstraint.constant = constant
    }
}

@MainActor
final class TerminalViewCoordinator {
    var terminalView: ShellTerminalView?
}

struct TerminalViewContainer: UIViewRepresentable {
    let session: SSHShellSession
    let fontSize: Double
    let colorScheme: ColorScheme
    let isInputFocusAllowed: Bool
    let shouldRestoreInputFocus: Bool
    let onInputFocusChange: ((Bool) -> Void)?
    let onOpenPanePicker: (() -> Void)?
    let onError: (String) -> Void
    let onClosed: () -> Void

    init(
        session: SSHShellSession,
        fontSize: Double = 14,
        colorScheme: ColorScheme,
        isInputFocusAllowed: Bool = true,
        shouldRestoreInputFocus: Bool = false,
        onInputFocusChange: ((Bool) -> Void)? = nil,
        onOpenPanePicker: (() -> Void)? = nil,
        onClosed: @escaping () -> Void = {},
        onError: @escaping (String) -> Void
    ) {
        self.session = session
        self.fontSize = fontSize
        self.colorScheme = colorScheme
        self.isInputFocusAllowed = isInputFocusAllowed
        self.shouldRestoreInputFocus = shouldRestoreInputFocus
        self.onInputFocusChange = onInputFocusChange
        self.onOpenPanePicker = onOpenPanePicker
        self.onError = onError
        self.onClosed = onClosed
    }

    func makeCoordinator() -> TerminalViewCoordinator {
        TerminalViewCoordinator()
    }

    func makeUIView(context: Context) -> TerminalChromeView {
        let terminalView = ShellTerminalView(frame: .zero)
        terminalView.updateAppearance(for: colorScheme)
        terminalView.updateFontSize(fontSize)
        terminalView.shouldRestoreInputFocus = shouldRestoreInputFocus
        terminalView.onInputFocusChange = onInputFocusChange
        terminalView.onOpenPanePicker = onOpenPanePicker
        terminalView.start(
            session: session,
            onError: onError,
            onClosed: onClosed
        )
        terminalView.updateInputFocus(isAllowed: isInputFocusAllowed)
        context.coordinator.terminalView = terminalView
        return TerminalChromeView(terminalView: terminalView)
    }

    func updateUIView(_ chromeView: TerminalChromeView, context: Context) {
        guard let terminalView = context.coordinator.terminalView else { return }
        terminalView.updateAppearance(for: colorScheme)
        terminalView.updateFontSize(fontSize)
        terminalView.shouldRestoreInputFocus = shouldRestoreInputFocus
        terminalView.onInputFocusChange = onInputFocusChange
        terminalView.onOpenPanePicker = onOpenPanePicker
        terminalView.updateInputFocus(isAllowed: isInputFocusAllowed)
        terminalView.updateSession(
            session: session,
            onError: onError,
            onClosed: onClosed
        )
    }

    static func dismantleUIView(
        _ chromeView: TerminalChromeView,
        coordinator: TerminalViewCoordinator
    ) {
        coordinator.terminalView?.stop()
    }
}

@MainActor
final class ShellTerminalView: TerminalView, @preconcurrency TerminalViewDelegate,
    UIGestureRecognizerDelegate {
    var session: SSHShellSession?
    var sessionIdentity: ObjectIdentifier?
    /// Exposes the bar independently of UIKit's first-responder presentation.
    private(set) lazy var shortcutBar: MudiTerminalShortcutBar? = {
        MudiTerminalShortcutBar(terminalView: self) { [weak self] in
            self?.onOpenPanePicker?()
        }
    }()
    /// Invoked by the shortcut bar's Jump To button; wired to the pane
    /// picker callback owned by the hosting screen.
    var onOpenPanePicker: (() -> Void)?
    private(set) var isInputFocusAllowed = true
    /// Mirrors UIKit's own state restoration: when the terminal had keyboard
    /// focus before a background retakeover replaced its control session,
    /// the recreated view reacquires focus once it is ready.
    var shouldRestoreInputFocus = false
    var onInputFocusChange: ((Bool) -> Void)?
    private var suppressFocusCallbacks = false
    private(set) var becomeFirstResponderRequestCount = 0
    private(set) var resignFirstResponderRequestCount = 0
    /// Bottom pin for the persistent shortcut bar; managed by the
    /// TerminalPersistentShortcutBar extension.
    var shortcutBarBottomConstraint: NSLayoutConstraint?
    /// Most recent keyboard frame from the keyboard notifications.
    var lastKeyboardFrameEnd: CGRect?
    private var outputTask: Task<Void, Never>?
    var didCloseNormally = false
    var onError: ((String) -> Void)?
    var onClosed: (() -> Void)?
    private var compositionInputDelegate: TerminalCompositionInputDelegate?
    private var compositionState = TerminalCompositionState()
    var remoteScrollbackEnabled = false
    var remoteScrollGesture: UIPanGestureRecognizer?
    var remoteScrollCapabilityTask: Task<Void, Never>?
    var remoteScrollTask: Task<Void, Never>?
    var remoteScrollLastTranslation: CGFloat = 0
    var remoteScrollDistance: CGFloat = 0
    var remoteScrollInertiaTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        let compositionInputDelegate = TerminalCompositionInputDelegate()
        self.compositionInputDelegate = compositionInputDelegate
        compositionInputDelegate.onTextChange = { [weak self] textInput in
            self?.updateComposition(from: textInput)
        }
        inputDelegate = compositionInputDelegate
        terminalDelegate = self
        accessibilityIdentifier = "ssh-terminal"
        isOpaque = true
        contentInsetAdjustmentBehavior = .never
        showsVerticalScrollIndicator = false
        alwaysBounceHorizontal = false
        alwaysBounceVertical = true
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
        // The shortcut bar is persistent (always pinned above the bottom
        // edge) rather than a keyboard accessory, so SwiftTerm's stock
        // accessory must not come back when the keyboard appears.
        inputAccessoryView = nil
        installKeyboardFrameObserver()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        ensureShortcutBarAttached()
    }

    override func layoutSubviews() {
        ensureShortcutBarAttached()
        super.layoutSubviews()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        updateShortcutBarOffset()
    }

    // MARK: Persistent shortcut bar lifecycle hooks

    // The pin/install/keyboard-riding implementation lives in the
    // TerminalPersistentShortcutBar extension so this class stays focused
    // on session and composition concerns.

    override func becomeFirstResponder() -> Bool {
        becomeFirstResponderRequestCount += 1
        let didBecome = super.becomeFirstResponder()
        if didBecome, !suppressFocusCallbacks {
            onInputFocusChange?(true)
        }
        return didBecome
    }

    override func resignFirstResponder() -> Bool {
        resignFirstResponderRequestCount += 1
        let didResign = super.resignFirstResponder()
        if didResign, !suppressFocusCallbacks {
            onInputFocusChange?(false)
        }
        return didResign
    }

    func updateInputFocus(isAllowed: Bool) {
        let wasAllowed = isInputFocusAllowed
        isInputFocusAllowed = isAllowed
        guard !isAllowed, wasAllowed || isFirstResponder else { return }
        _ = resignFirstResponder()
    }

    func start(
        session: SSHShellSession,
        onError: @escaping (String) -> Void,
        onClosed: @escaping () -> Void = {}
    ) {
        guard outputTask == nil else { return }
        self.session = session
        sessionIdentity = ObjectIdentifier(session)
        self.onError = onError
        self.onClosed = onClosed
        didCloseNormally = false
        suppressFocusCallbacks = false
        installCompositionInputDelegate()
        terminalDelegate = self
        let sessionIdentity = ObjectIdentifier(session)
        loadRemoteScrollbackCapability(for: session, identity: sessionIdentity)

        outputTask = Task { [weak self, session, sessionIdentity] in
            await self?.consumeOutput(of: session, identity: sessionIdentity)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.sessionIdentity == sessionIdentity
            else { return }
            if shouldRestoreInputFocus, isInputFocusAllowed {
                shouldRestoreInputFocus = false
                _ = becomeFirstResponder()
            }
            sendCurrentSize()
        }
    }

    func updateSession(
        session: SSHShellSession,
        onError: @escaping (String) -> Void,
        onClosed: @escaping () -> Void = {}
    ) {
        self.onError = onError
        self.onClosed = onClosed
        guard sessionIdentity != ObjectIdentifier(session) else { return }
        stop()
        start(
            session: session,
            onError: onError,
            onClosed: onClosed
        )
    }

    func updateAppearance(for colorScheme: ColorScheme) {
        let appearance = TerminalAppearance.colors(for: colorScheme)
        nativeBackgroundColor = appearance.background
        nativeForegroundColor = appearance.foreground
        backgroundColor = appearance.background
        caretColor = appearance.foreground
        caretTextColor = appearance.background
        shortcutBar?.updateAppearance(
            background: appearance.background,
            foreground: appearance.foreground
        )
    }

    func updateFontSize(_ fontSize: Double) {
        guard fontSize.isFinite, fontSize > 0 else { return }
        guard abs(font.pointSize - fontSize) > 0.001
                || !TerminalFont.hasSymbolsCascade(in: font)
        else { return }

        // Point-size equality is not enough: SwiftTerm starts at 12pt and a
        // same-size update must still install the symbol cascade.
        font = TerminalFont.font(ofSize: fontSize)
    }

    func stop() {
        // UIKit resigns first responder when the view leaves the window. That
        // implicit resign is teardown, not a user keyboard dismissal, so it
        // must not clear the remembered focus used for restoration.
        suppressFocusCallbacks = true
        outputTask?.cancel()
        outputTask = nil
        remoteScrollCapabilityTask?.cancel()
        remoteScrollCapabilityTask = nil
        remoteScrollTask?.cancel()
        remoteScrollTask = nil
        remoteScrollInertiaTask?.cancel()
        remoteScrollInertiaTask = nil
        if let remoteScrollGesture {
            removeGestureRecognizer(remoteScrollGesture)
        }
        remoteScrollGesture = nil
        remoteScrollbackEnabled = false
        remoteScrollDistance = 0
        remoteScrollLastTranslation = 0
        isScrollEnabled = true
        compositionInputDelegate?.onTextChange = nil
        compositionState.update(markedText: nil)
        shortcutBar?.updateComposition(markedText: nil)
        terminalDelegate = nil
        didCloseNormally = false
        session = nil
        sessionIdentity = nil
        onError = nil
        onClosed = nil
    }

    private func installCompositionInputDelegate() {
        guard let compositionInputDelegate else { return }
        if inputDelegate !== compositionInputDelegate {
            compositionInputDelegate.downstream = inputDelegate
            inputDelegate = compositionInputDelegate
        }
        compositionInputDelegate.onTextChange = { [weak self] textInput in
            self?.updateComposition(from: textInput)
        }
    }

    private func updateComposition(from textInput: UITextInput) {
        let markedText: String?
        if let markedTextRange = textInput.markedTextRange {
            markedText = textInput.text(in: markedTextRange)
        } else {
            markedText = nil
        }
        let previousText = compositionState.visibleText
        compositionState.update(markedText: markedText)
        guard previousText != compositionState.visibleText else { return }
        shortcutBar?.updateComposition(
            markedText: compositionState.visibleText
        )
    }

}

extension ShellTerminalView {
    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Array(data)
        guard !bytes.isEmpty, let session else { return }
        Task {
            do {
                try await session.send(bytes)
            } catch {
                report(error)
            }
        }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        resize(columns: newCols, rows: newRows)
    }

    func scrolled(source: TerminalView, position: Double) {}

    func setTerminalTitle(source: TerminalView, title: String) {}

    func clipboardCopy(source: TerminalView, content: Data) {
        if let text = String(data: content, encoding: .utf8) {
            UIPasteboard.general.string = text
        } else {
            UIPasteboard.general.setValue(content, forPasteboardType: "public.data")
        }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link) else { return }
        UIApplication.shared.open(url)
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    private func sendCurrentSize() {
        let terminal = getTerminal()
        resize(columns: terminal.cols, rows: terminal.rows)
    }

    private func resize(columns: Int, rows: Int) {
        guard columns > 0, rows > 0, let session else { return }
        Task { [weak self] in
            do {
                try await session.resize(columns: columns, rows: rows)
            } catch is SSHShellError {
                return
            } catch {
                self?.report(error)
            }
        }
    }

    func report(_ error: Error) {
        guard !didCloseNormally else { return }
        let message: String
        if let shellError = error as? SSHShellError, let description = shellError.errorDescription {
            message = description
        } else {
            message = "The SSH shell connection was lost."
        }
        onError?(message)
    }
}
