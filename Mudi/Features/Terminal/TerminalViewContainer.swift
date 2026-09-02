import HerdrKit
@preconcurrency import SwiftTerm
import SwiftUI

/// Exact arithmetic for the visible SwiftTerm grid. The viewport may have a
/// fractional-cell remainder, but rendered terminal content is always the
/// whole-row height represented here; nothing is allowed to remain as a stale
/// row below the active grid after a font or chrome resize.
struct TerminalGridLayoutMetrics: Equatable {
    let viewportHeight: CGFloat
    let cellHeight: CGFloat
    let rows: Int

    init(viewportHeight: CGFloat, cellHeight: CGFloat) {
        self.viewportHeight = viewportHeight
        self.cellHeight = cellHeight
        guard viewportHeight > 0, viewportHeight.isFinite,
              cellHeight > 0, cellHeight.isFinite
        else {
            rows = 0
            return
        }
        rows = Int(viewportHeight / cellHeight)
    }

    var contentHeight: CGFloat {
        CGFloat(rows) * cellHeight
    }

    var trailingRemainder: CGFloat {
        max(0, viewportHeight - contentHeight)
    }
}

/// UIKit container that hosts the terminal scroll view and reserves the
/// persistent shortcut-bar strip below it: the scroll view's bottom edge
/// sits above the bar, so SwiftTerm lays out grid rows only in the truly
/// visible region, `terminal.resize` receives the true visible rows, and
/// the bar can never cover content (keyboard up or down).
final class TerminalChromeView: UIView {
    private(set) var terminalView: ShellTerminalView!
    private var terminalBottomConstraint: NSLayoutConstraint!
    private(set) var reservedBottom: CGFloat = 0

    init(terminalView: ShellTerminalView) {
        super.init(frame: .zero)
        self.terminalView = terminalView
        clipsToBounds = true
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
    /// end above the bar. A changed reservation also invalidates the terminal
    /// view's full-frame display so old keyboard geometry cannot be painted
    /// into the newly exposed area.
    func setReservedBottom(_ height: CGFloat) {
        let sanitizedHeight = height.isFinite ? max(height, 0) : 0
        guard abs(reservedBottom - sanitizedHeight) > 0.25 else { return }
        reservedBottom = sanitizedHeight
        terminalBottomConstraint.constant = -sanitizedHeight
        terminalView.requestTerminalRelayout()
        setNeedsLayout()
    }
}

@MainActor
final class TerminalViewCoordinator {
    var terminalView: ShellTerminalView?
}

struct TerminalViewContainer: UIViewRepresentable {
    let session: SSHShellSession
    let fontSize: Double
    let fontFamily: String?
    let theme: TerminalTheme?
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
        fontFamily: String? = nil,
        theme: TerminalTheme? = nil,
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
        self.fontFamily = fontFamily
        self.theme = theme
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
        if let theme {
            terminalView.apply(theme: theme)
        } else {
            terminalView.updateAppearance(for: colorScheme)
        }
        terminalView.updateFont(familyName: fontFamily, pointSize: fontSize)
        terminalView.shouldRestoreInputFocus = shouldRestoreInputFocus
        terminalView.onInputFocusChange = onInputFocusChange
        terminalView.onOpenPanePicker = onOpenPanePicker
        let chromeView = TerminalChromeView(terminalView: terminalView)
        terminalView.start(
            session: session,
            onError: onError,
            onClosed: onClosed
        )
        terminalView.updateInputFocus(isAllowed: isInputFocusAllowed)
        context.coordinator.terminalView = terminalView
        return chromeView
    }

    func updateUIView(_ chromeView: TerminalChromeView, context: Context) {
        guard let terminalView = context.coordinator.terminalView else { return }
        if let theme {
            if terminalView.appliedTheme != theme {
                terminalView.apply(theme: theme)
            }
        } else {
            terminalView.updateAppearance(for: colorScheme)
        }
        terminalView.updateFont(familyName: fontFamily, pointSize: fontSize)
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
    private(set) var appliedTheme: TerminalTheme? = nil
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
    private var needsInitialSizeSync = false
    private var initialSizeSyncScheduled = false
    private var pendingTerminalRelayout = false
    private var lastLaidOutBoundsSize = CGSize.zero
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

        let didChangeSize = bounds.size != lastLaidOutBoundsSize
        lastLaidOutBoundsSize = bounds.size
        if didChangeSize || pendingTerminalRelayout {
            pendingTerminalRelayout = false
            reconcileTerminalGridLayout()
            // SwiftTerm clears its own dirty region on a font/viewport
            // change, but the UIKit view may have been painted at the old
            // keyboard height. Redraw the complete current viewport so a
            // newly exposed region cannot retain stale rows.
            setNeedsDisplay(bounds)
        }
        scheduleInitialSizeSync()
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
        needsInitialSizeSync = true
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
            self.scheduleInitialSizeSync()
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

    func requestTerminalRelayout() {
        pendingTerminalRelayout = true
        setNeedsLayout()
        if bounds.width > 0, bounds.height > 0 {
            setNeedsDisplay(bounds)
        }
    }

    var terminalCellHeight: CGFloat {
        let rows = getTerminal().rows
        guard rows > 0 else { return 0 }
        return getOptimalFrameSize().height / CGFloat(rows)
    }

    var terminalGridLayoutMetrics: TerminalGridLayoutMetrics {
        TerminalGridLayoutMetrics(
            viewportHeight: bounds.height,
            cellHeight: terminalCellHeight
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
        requestTerminalRelayout()
    }

    /// Applies the complete theme to SwiftTerm and to the UIKit chrome. The
    /// base sixteen colors are installed without quantizing or rewriting the
    /// terminal's true-color foreground/background values.
    func apply(theme: TerminalTheme) {
        appliedTheme = theme
        let terminal = getTerminal()
        terminal.ansi256PaletteStrategy = swiftTermPaletteStrategy(
            theme.extendedPaletteStrategy
        )
        // Terminal.installPalette updates the engine only. TerminalView owns
        // a separate 256-entry UIColor cache, so use its public integration
        // method to invalidate already-rendered ANSI cells as well.
        installColors(theme.ansi16.map(swiftTermColor))
        nativeBackgroundColor = theme.defaultBackground.uiColor
        nativeForegroundColor = theme.defaultForeground.uiColor
        backgroundColor = theme.defaultBackground.uiColor
        caretColor = theme.cursor.uiColor
        // A block cursor paints the cell foreground with caretTextColor. The
        // theme background keeps the glyph visible even when cursor and
        // default foreground intentionally share the same color.
        caretTextColor = theme.defaultBackground.uiColor
        selectedTextBackgroundColor = theme.selection.uiColor
        selectedTextForegroundColor = theme.bold.uiColor
        terminal.cursorColor = swiftTermColor(theme.cursor)
        shortcutBar?.updateAppearance(
            background: theme.defaultBackground.uiColor,
            foreground: theme.defaultForeground.uiColor
        )

        if case let .explicit(palette) = theme.extendedPaletteStrategy {
            installExplicitPalette(palette)
        }
        requestTerminalRelayout()
    }

    func updateFont(familyName: String?, pointSize: Double) {
        guard pointSize.isFinite, pointSize > 0 else { return }
        if let familyName,
           let selectedFont = TerminalFontRegistry.font(
               familyName: familyName,
               pointSize: pointSize
           ) {
            guard font.familyName != selectedFont.familyName
                    || abs(font.pointSize - selectedFont.pointSize) > 0.001
            else { return }
            installFontWithoutSoftReset(selectedFont)
            return
        }
        updateFontSize(pointSize)
    }

    func updateFontSize(_ fontSize: Double) {
        guard fontSize.isFinite, fontSize > 0 else { return }
        if let selectedFont = TerminalFontRegistry.font(
            familyName: font.familyName,
            pointSize: fontSize
        ) {
            guard abs(selectedFont.pointSize - font.pointSize) > 0.001
            else { return }
            installFontWithoutSoftReset(selectedFont)
            return
        }
        guard abs(font.pointSize - fontSize) > 0.001
                || !TerminalFont.hasSymbolsCascade(in: font)
        else { return }

        // Point-size equality is not enough: SwiftTerm starts at 12pt and a
        // same-size update must still install the symbol cascade.
        installFontWithoutSoftReset(TerminalFont.font(ofSize: fontSize))
    }

    /// SwiftTerm 1.15's public `font` setter calls `resetFont()`, which calls
    /// the public view `resize()` and therefore sends DECSTR/softReset to the
    /// terminal engine. During a live session that destroys application modes
    /// (for example vim's application cursor mode). Keep the view's frame at
    /// zero while installing the font so `resetFont()` only recomputes its
    /// cached metrics. Then two real layout passes take the old-size → zero →
    /// current-size path through SwiftTerm's `processSizeChange`, whose engine
    /// resize does not soft-reset. Finally reapply the current theme because
    /// SwiftTerm clears render caches as part of its font reset.
    private func installFontWithoutSoftReset(_ newFont: UIFont) {
        guard session != nil,
              bounds.width > 0,
              bounds.height > 0
        else {
            font = newFont
            requestTerminalRelayout()
            return
        }

        let originalFrame = frame
        let originalBounds = bounds
        let originalContentOffset = contentOffset

        // `resetFont()` tests frame dimensions before calling the destructive
        // public resize. A zero-sized intermediate layout makes that setter a
        // metrics-only operation while preserving the live Terminal instance.
        frame = CGRect(origin: originalFrame.origin, size: .zero)
        font = newFont
        setNeedsLayout()
        layoutIfNeeded()

        frame = originalFrame
        bounds = originalBounds
        setNeedsLayout()
        layoutIfNeeded()
        setContentOffset(originalContentOffset, animated: false)
        sendCurrentSize()

        if let appliedTheme {
            apply(theme: appliedTheme)
        } else {
            requestTerminalRelayout()
        }
    }

    private func scheduleInitialSizeSync() {
        guard needsInitialSizeSync,
              !initialSizeSyncScheduled,
              bounds.width > 0,
              bounds.height > 0,
              session != nil
        else { return }
        initialSizeSyncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            initialSizeSyncScheduled = false
            guard needsInitialSizeSync,
                  bounds.width > 0,
                  bounds.height > 0,
                  session != nil
            else { return }
            // Let the chrome finish applying its current keyboard/bar
            // reservation before the first PTY size is sent. This avoids
            // booting a session at the old full-height 24-row geometry.
            superview?.layoutIfNeeded()
            guard bounds.width > 0, bounds.height > 0 else { return }
            needsInitialSizeSync = false
            sendCurrentSize()
        }
    }

    private func reconcileTerminalGridLayout() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let terminal = getTerminal()
        guard terminal.cols > 0, terminal.rows > 0 else { return }
        let optimalSize = getOptimalFrameSize()
        let cellWidth = optimalSize.width / CGFloat(terminal.cols)
        guard cellWidth.isFinite, cellWidth > 0,
              terminalCellHeight.isFinite, terminalCellHeight > 0
        else { return }

        let layout = terminalGridLayoutMetrics
        let expectedColumns = max(Int(bounds.width / cellWidth), 1)
        let expectedRows = max(layout.rows, 1)
        guard terminal.cols != expectedColumns || terminal.rows != expectedRows
        else { return }
        terminal.resize(cols: expectedColumns, rows: expectedRows)
        setNeedsDisplay(bounds)
    }

    private func swiftTermPaletteStrategy(
        _ strategy: TerminalThemePaletteStrategy
    ) -> Ansi256PaletteStrategy {
        switch strategy {
        case .xterm, .explicit:
            return .xterm
        case .base16Lab:
            return .base16Lab
        case .base16LabHarmonious:
            return .base16LabHarmonious
        }
    }

    private func swiftTermColor(_ color: TerminalRGBColor) -> SwiftTerm.Color {
        SwiftTerm.Color(
            red: UInt16(color.red) * 257,
            green: UInt16(color.green) * 257,
            blue: UInt16(color.blue) * 257
        )
    }

    private func installExplicitPalette(_ palette: [TerminalRGBColor]) {
        guard palette.count == 240 else { return }
        let assignments = palette.enumerated().map { offset, color in
            let index = offset + 16
            return "\u{1b}]4;\(index);#\(String(format: "%02x%02x%02x", color.red, color.green, color.blue))\u{07}"
        }
        getTerminal().feed(text: assignments.joined())
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
        needsInitialSizeSync = false
        initialSizeSyncScheduled = false
        pendingTerminalRelayout = false
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
