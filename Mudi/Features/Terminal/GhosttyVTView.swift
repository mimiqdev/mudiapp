import CoreText
import GhosttyVt
import HerdrKit
import UIKit

/// Opt-in VT-backed UIKit surface with Mudi-owned CoreText drawing and input.
/// Never creates a connection or embeds SwiftTerm; its adapter binds the
/// already-connected session and its chrome uses the shared TerminalHost.
@MainActor
final class GhosttyVTView: UIView {
    enum InitializationError: Error {
        case gridTooLarge
    }

    var isModifierFocusHandoff = false

    let terminal: GhosttyVt.Terminal
    private(set) var screen = GhosttyVTScreen()
    private(set) var font: UIFont
    private(set) var cellSize: CGSize
    var onGridResize: ((GhosttyVt.Terminal.Size) -> Void)?
    var onRenderError: ((Error) -> Void)?
    private var lastPixelCellSize: CGSize = .zero
    let inputStorage = GhosttyVTInputStorage()
    weak var inputDelegate: (any UITextInputDelegate)?
    lazy var tokenizer: any UITextInputTokenizer = UITextInputStringTokenizer(textInput: self)
    var markedTextStyle: [NSAttributedString.Key: Any]?
    var onInput: ((GhosttyVTInputAction) -> Void)?
    var onCompositionChange: ((String?) -> Void)?
    var onModifiersConsumed: (() -> Void)?
    var controlModifier = false
    var metaModifier = false
    var isInputFocusAllowed = true
    var shouldRestoreInputFocus = false
    var onInputFocusChange: ((Bool) -> Void)?
    var onOpenPanePicker: (() -> Void)?
    var thumbArcPreferences = ThumbArcPreferences()
    var appliedTheme: TerminalTheme?
    var sessionAdapter: GhosttyVTSessionAdapter?
    var onHostError: ((String) -> Void)?
    var onHostClosed: (() -> Void)?
    var suppressFocusCallbacks = false
    var lastKeyboardFrameEnd: CGRect?
    var barBottomConstraint: NSLayoutConstraint?
    var barHeightConstraint: NSLayoutConstraint?
    var keyboardObserver: TerminalNotificationToken?
    var thumbArcController: TerminalHostThumbArcController?
    var viewportController: GhosttyVTViewportController?
    var terminalSelection: GhosttyVTCellSelection?
    var scrollCapability: TerminalScrollCapability = .none
    var isScrollOwnerResolved = true
    var onScroll: ((TerminalScrollDirection, Int, CGPoint) -> Void)?
    var hardwareKeyRepeat: Timer?
    lazy var shortcutBar: MudiTerminalShortcutBar? = MudiTerminalShortcutBar(terminalView: self) { [weak self] in
        self?.onOpenPanePicker?()
    }
    var keyboardType: UIKeyboardType = .default
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var returnKeyType: UIReturnKeyType = .default
    var enablesReturnKeyAutomatically = false
    var isSecureTextEntry = false

    init(configuration: GhosttyVt.Terminal.Configuration = .init()) throws {
        guard configuration.columns <= GhosttyVTGridGeometry.maximumColumns,
              configuration.rows <= GhosttyVTGridGeometry.maximumRows else {
            throw InitializationError.gridTooLarge
        }
        // The real throwing API remains visible to the future A/B host.
        // In particular invalidSize/OOM must not masquerade as success.
        terminal = try GhosttyVt.Terminal(configuration: configuration)
        font = TerminalFont.font(ofSize: TerminalFont.defaultPointSize)
        cellSize = Self.metrics(for: font)
        super.init(frame: .zero)
        isOpaque = true
        clipsToBounds = true
        contentMode = .redraw
        accessibilityIdentifier = "ghostty-vt-surface"
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
        onCompositionChange = { [weak self] in self?.shortcutBar?.updateComposition(markedText: $0) }
        onModifiersConsumed = { [weak self] in self?.shortcutBar?.updateModifierState() }
        installHostKeyboardObserver()
        thumbArcController = TerminalHostThumbArcController(host: self)
        viewportController = GhosttyVTViewportController(view: self)
        try refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var canBecomeFirstResponder: Bool { isInputFocusAllowed }

    override func becomeFirstResponder() -> Bool {
        guard isInputFocusAllowed else { return false }
        let result = super.becomeFirstResponder()
        if result { shortcutBar?.dismissAllPopups() }
        if result, !suppressFocusCallbacks, !isModifierFocusHandoff { onInputFocusChange?(true) }
        return result
    }

    override func resignFirstResponder() -> Bool {
        stopHardwareKeyRepeat()
        cancelComposition()
        let result = super.resignFirstResponder()
        if result, !suppressFocusCallbacks, !isModifierFocusHandoff, window != nil,
           UIApplication.shared.applicationState == .active { onInputFocusChange?(false) }
        return result
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        ensureHostShortcutBarAttached()
        restoreHostInputFocusIfRequested()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = handleHardwarePresses(presses)
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        stopHardwareKeyRepeat()
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        stopHardwareKeyRepeat()
        super.pressesCancelled(presses, with: event)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(copy(_:)) { return markedTextRange == nil && selectedTerminalText != nil }
        if action == #selector(paste(_:)) { return isInputFocusAllowed && markedTextRange == nil && UIPasteboard.general.hasStrings }
        return super.canPerformAction(action, withSender: sender)
    }

    override func copy(_ sender: Any?) {
        guard markedTextRange == nil, let text = selectedTerminalText else { return }
        UIPasteboard.general.string = text
    }

    /// Effects are owned by the caller; in the session adapter writeToPty
    /// goes back through the same session used by input. No replies are fed
    /// into the screen or discarded by the renderer.
    @discardableResult
    func feed(_ data: Data) throws -> [GhosttyVt.Terminal.Event] {
        terminal.feed(data)
        try refresh()
        return terminal.drainEvents()
    }

    func refresh() throws {
        let previous = terminalSelection == nil ? nil : screen
        screen.apply(try terminal.update())
        // A colour-only theme update retains selection. Reflow/output/scroll
        // that actually changes cell text invalidates stale viewport indices.
        if let previous, !GhosttyVTCellSelection.contentMatches(previous, screen) { clearTerminalSelection() }
        backgroundColor = screen.theme?.background.uiColor
        setNeedsDisplay()
    }

    func updateFont(familyName: String?, pointSize: Double) {
        guard pointSize.isFinite, pointSize > 0, pointSize <= 128 else { return }
        let selected = familyName.flatMap {
            TerminalFontRegistry.font(familyName: $0, pointSize: pointSize)
        } ?? TerminalFont.font(ofSize: pointSize)
        guard font.fontDescriptor != selected.fontDescriptor || font.pointSize != selected.pointSize else { return }
        font = selected
        cellSize = Self.metrics(for: selected)
        // No reset/soft reset: the same VT instance retains modes/scrollback.
        setNeedsLayout()
        setNeedsDisplay()
    }

    override func layoutSubviews() {
        ensureHostShortcutBarAttached()
        super.layoutSubviews()
        guard let size = GhosttyVTGridGeometry.size(viewport: bounds.size, cell: cellSize) else { return }
        let scale = window?.screen.scale ?? contentScaleFactor
        let pixelSize = CGSize(width: ceil(cellSize.width * scale), height: ceil(cellSize.height * scale))
        let changedGrid = size != screen.size
        guard changedGrid || pixelSize != lastPixelCellSize else { return }
        do {
            try terminal.resize(to: size, cellWidth: Self.pixelDimension(pixelSize.width),
                                cellHeight: Self.pixelDimension(pixelSize.height))
            try refresh()
            lastPixelCellSize = pixelSize
            if changedGrid { onGridResize?(size) }
        } catch {
            onRenderError?(error)
        }
    }

    /// VT width/column metadata drives placement, including graphemes which
    /// contain multiple scalars and wide cells which span two columns.
    func glyphRect(for cell: TerminalFrame.Cell, row: Int) -> CGRect? {
        guard row >= 0, row < Int(screen.size.rows), cell.column < screen.size.columns else { return nil }
        let columns: Int
        switch cell.width {
        case .spacerHead, .spacerTail: return nil
        case .wide: columns = min(2, Int(screen.size.columns - cell.column))
        case .narrow: columns = 1
        }
        return CGRect(x: CGFloat(cell.column) * cellSize.width, y: CGFloat(row) * cellSize.height,
                      width: CGFloat(columns) * cellSize.width, height: cellSize.height)
    }

    /// Uses the same line construction for observation and real drawing. The
    /// UIFont descriptor carries Mudi's registered Nerd Font cascade; CoreText
    /// chooses fallback glyph runs instead of a home-grown shaper.
    func glyphLine(for cell: TerminalFrame.Cell, foreground: UIColor) -> CTLine {
        var traits = font.fontDescriptor.symbolicTraits
        if cell.style.isBold { traits.insert(.traitBold) }
        if cell.style.isItalic { traits.insert(.traitItalic) }
        let descriptor = font.fontDescriptor.withSymbolicTraits(traits) ?? font.fontDescriptor
        let ctFont = CTFontCreateWithFontDescriptor(descriptor, font.pointSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): ctFont,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): foreground.cgColor,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: cell.text, attributes: attributes))
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), let theme = screen.theme else { return }
        context.setFillColor(theme.background.uiColor.cgColor)
        context.fill(bounds)
        // Two passes: painting a spacer background AFTER its wide glyph would
        // erase the right half of that glyph. All backgrounds precede text.
        for row in screen.rows.compactMap({ $0 }) {
            for cell in row.cells {
                let backgroundRect = CGRect(x: CGFloat(cell.column) * cellSize.width,
                                            y: CGFloat(row.index) * cellSize.height,
                                            width: cellSize.width, height: cellSize.height)
                guard backgroundRect.intersects(rect) else { continue }
                context.setFillColor(colors(for: cell, theme: theme, row: Int(row.index)).background.cgColor)
                context.fill(backgroundRect)
            }
        }
        for row in screen.rows.compactMap({ $0 }) {
            for cell in row.cells {
                guard let cellRect = glyphRect(for: cell, row: Int(row.index)), cellRect.intersects(rect),
                      !cell.style.isInvisible, !cell.text.isEmpty else { continue }
                drawGlyph(cell, in: cellRect, foreground: colors(for: cell, theme: theme, row: Int(row.index)).foreground, context: context)
            }
        }
        drawCursor(theme: theme, context: context)
    }

    private func colors(for cell: TerminalFrame.Cell, theme: TerminalFrame.Theme, row: Int) -> (foreground: UIColor, background: UIColor) {
        var foreground = (cell.resolvedForeground ?? theme.foreground).uiColor
        var background = (cell.resolvedBackground ?? theme.background).uiColor
        if cell.style.isInverse { swap(&foreground, &background) }
        if let bright = Self.boldBrightForeground(for: cell.style, palette: theme.palette) { foreground = bright.uiColor }
        if selectionContains(cell, row: row) {
            background = appliedTheme?.selection.uiColor ?? .systemBlue
            foreground = appliedTheme?.bold.uiColor ?? theme.background.uiColor
        }
        if cell.style.isFaint { foreground = foreground.withAlphaComponent(0.5) }
        return (foreground, background)
    }

    /// The VT FG_COLOR API deliberately leaves bold handling to the renderer.
    /// Keep SwiftTerm 1.15 (`dd2fb8ac`) default `useBrightColors` behaviour
    /// (`AppleTerminalView.mapColor`): after the inverse swap, a bold
    /// foreground that is a palette index `< 7` uses `index + 8`. Index 7,
    /// explicit bright/256 (index ≥ 8), RGB, default colours and backgrounds
    /// are unchanged. Decided from the VT style's palette index, never from RGB.
    static func boldBrightForeground(for style: TerminalFrame.Style, palette: [TerminalFrame.RGBColor]) -> TerminalFrame.RGBColor? {
        guard style.isBold, case .palette(let index)? = style.isInverse ? style.background : style.foreground,
              index < 7, palette.indices.contains(Int(index) + 8) else { return nil }
        return palette[Int(index) + 8]
    }

    private func drawGlyph(_ cell: TerminalFrame.Cell, in rect: CGRect, foreground: UIColor, context: CGContext) {
        let line = glyphLine(for: cell, foreground: foreground)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: rect)
        context.textMatrix = .identity
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: width > rect.width ? rect.width / width : 1, y: -1)
        context.textPosition = CGPoint(x: 0, y: max(0, (rect.height - ascent - descent) / 2) + descent)
        CTLineDraw(line, context)
        // Full decoration styles, blink scheduling and ligature batching are
        // deliberately deferred, not simulated as completed interactions.
    }

    private func drawCursor(theme: TerminalFrame.Theme, context: CGContext) {
        guard let cursor = screen.cursor, cursor.isVisible, let position = cursor.position,
              position.row < screen.size.rows, position.column < screen.size.columns else { return }
        var column = Int(position.column)
        if cursor.isWideTail { column = max(0, column - 1) }
        let cell = screen.rows[Int(position.row)]?.cells.first { Int($0.column) == column }
        let width = (cell?.width == .wide ? 2 : 1) * cellSize.width
        let rect = CGRect(x: CGFloat(column) * cellSize.width, y: CGFloat(position.row) * cellSize.height,
                          width: min(width, CGFloat(screen.size.columns) * cellSize.width - CGFloat(column) * cellSize.width),
                          height: cellSize.height)
        let color = (theme.cursor ?? theme.foreground).uiColor
        context.setFillColor(color.cgColor)
        switch cursor.style {
        case .bar:
            context.fill(CGRect(x: rect.minX, y: rect.minY, width: min(2, rect.width), height: rect.height))
        case .underline:
            context.fill(CGRect(x: rect.minX, y: rect.maxY - 2, width: rect.width, height: 2))
        case .hollowBlock:
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(1)
            context.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
        case .block:
            context.fill(rect)
            if let cell, !cell.style.isInvisible, !cell.text.isEmpty {
                drawGlyph(cell, in: rect, foreground: theme.background.uiColor, context: context)
            }
        }
    }

    private static func metrics(for font: UIFont) -> CGSize {
        let ctFont = CTFontCreateWithFontDescriptor(font.fontDescriptor, font.pointSize, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: "M", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): ctFont]))
        return CGSize(width: max(1, ceil(CTLineGetTypographicBounds(line, nil, nil, nil))),
                      height: max(1, ceil(CTFontGetAscent(ctFont) + CTFontGetDescent(ctFont) + CTFontGetLeading(ctFont))))
    }

    private static func pixelDimension(_ value: CGFloat) -> UInt32 {
        guard value.isFinite, value > 0 else { return 0 }
        return UInt32(min(CGFloat(UInt32.max), value))
    }
}

extension TerminalFrame.RGBColor {
    var uiColor: UIColor {
        UIColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255,
                blue: CGFloat(blue) / 255, alpha: 1)
    }
}
