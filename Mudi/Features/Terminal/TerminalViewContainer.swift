import HerdrKit
@preconcurrency import SwiftTerm
import SwiftUI

struct TerminalViewContainer: UIViewRepresentable {
    let session: SSHShellSession
    let fontSize: Double
    let colorScheme: ColorScheme
    let isInputFocusAllowed: Bool
    let shouldRestoreInputFocus: Bool
    let onInputFocusChange: ((Bool) -> Void)?
    let onError: (String) -> Void
    let onClosed: () -> Void

    init(
        session: SSHShellSession,
        fontSize: Double = 14,
        colorScheme: ColorScheme,
        isInputFocusAllowed: Bool = true,
        shouldRestoreInputFocus: Bool = false,
        onInputFocusChange: ((Bool) -> Void)? = nil,
        onClosed: @escaping () -> Void = {},
        onError: @escaping (String) -> Void
    ) {
        self.session = session
        self.fontSize = fontSize
        self.colorScheme = colorScheme
        self.isInputFocusAllowed = isInputFocusAllowed
        self.shouldRestoreInputFocus = shouldRestoreInputFocus
        self.onInputFocusChange = onInputFocusChange
        self.onError = onError
        self.onClosed = onClosed
    }

    func makeUIView(context: Context) -> ShellTerminalView {
        let terminalView = ShellTerminalView(frame: .zero)
        terminalView.updateAppearance(for: colorScheme)
        terminalView.updateFontSize(fontSize)
        terminalView.shouldRestoreInputFocus = shouldRestoreInputFocus
        terminalView.onInputFocusChange = onInputFocusChange
        terminalView.start(
            session: session,
            onError: onError,
            onClosed: onClosed
        )
        terminalView.updateInputFocus(isAllowed: isInputFocusAllowed)
        return terminalView
    }

    func updateUIView(_ terminalView: ShellTerminalView, context: Context) {
        terminalView.updateAppearance(for: colorScheme)
        terminalView.updateFontSize(fontSize)
        terminalView.shouldRestoreInputFocus = shouldRestoreInputFocus
        terminalView.onInputFocusChange = onInputFocusChange
        terminalView.updateInputFocus(isAllowed: isInputFocusAllowed)
        terminalView.updateSession(
            session: session,
            onError: onError,
            onClosed: onClosed
        )
    }

    static func dismantleUIView(_ terminalView: ShellTerminalView, coordinator: ()) {
        terminalView.stop()
    }
}

@MainActor
final class ShellTerminalView: TerminalView, @preconcurrency TerminalViewDelegate,
    UIGestureRecognizerDelegate {
    var session: SSHShellSession?
    var sessionIdentity: ObjectIdentifier?
    /// Exposes the bar independently of UIKit's first-responder presentation.
    private(set) lazy var shortcutBar: MudiTerminalShortcutBar? = {
        MudiTerminalShortcutBar(
            terminalView: self,
            onPageUp: { [weak self] in self?.pageUpFromShortcut() },
            onPageDown: { [weak self] in self?.pageDownFromShortcut() }
        )
    }()
    private(set) var isInputFocusAllowed = true
    /// Mirrors UIKit's own state restoration: when the terminal had keyboard
    /// focus before a background retakeover replaced its control session,
    /// the recreated view reacquires focus once it is ready.
    var shouldRestoreInputFocus = false
    var onInputFocusChange: ((Bool) -> Void)?
    private var suppressFocusCallbacks = false
    private(set) var becomeFirstResponderRequestCount = 0
    private(set) var resignFirstResponderRequestCount = 0
    private var outputTask: Task<Void, Never>?
    private var didCloseNormally = false
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
        inputAccessoryView = shortcutBar
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

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
            let output = await session.outputStream()
            do {
                for try await bytes in output {
                    guard !Task.isCancelled else { return }
                    guard let self,
                          self.sessionIdentity == sessionIdentity
                    else { return }
                    guard !bytes.isEmpty else { continue }
                    self.feed(byteArray: bytes[...])
                }
            } catch {
                guard !Task.isCancelled,
                      let self,
                      self.sessionIdentity == sessionIdentity
                else { return }
                await session.disconnect()
                guard !Task.isCancelled,
                      self.sessionIdentity == sessionIdentity
                else { return }
                self.report(error)
                return
            }

            guard !Task.isCancelled,
                  let self,
                  self.sessionIdentity == sessionIdentity
            else { return }
            self.didCloseNormally = true
            await session.disconnect()
            guard !Task.isCancelled,
                  self.sessionIdentity == sessionIdentity
            else { return }
            self.onClosed?()
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
