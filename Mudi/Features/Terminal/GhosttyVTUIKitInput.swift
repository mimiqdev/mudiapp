import CoreText
import GhosttyVt
import UIKit

/// UIKit owns preedit, VT owns terminal modes. None of this storage parses
/// output, mirrors the terminal screen, or retains already-committed text.
enum GhosttyVTInputAction {
    case key(GhosttyVt.Terminal.KeyEvent)
    case raw(Data)
    case paste(String, bracketed: Bool, appendEnter: Bool)
}

final class GhosttyVTInputStorage {
    var text = ""
    var selection = NSRange(location: 0, length: 0)
    var isMarked = false
    var length: Int { text.utf16.count }
}

private final class VTInputPosition: UITextPosition {
    let index: Int
    init(_ index: Int) { self.index = index; super.init() }
}
private final class VTInputRange: UITextRange {
    let lower: Int
    let upper: Int
    init(_ lower: Int, _ upper: Int) { self.lower = min(lower, upper); self.upper = max(lower, upper); super.init() }
    override var start: UITextPosition { VTInputPosition(lower) }
    override var end: UITextPosition { VTInputPosition(upper) }
    override var isEmpty: Bool { lower == upper }
}
private final class VTInputSelectionRect: UITextSelectionRect {
    private let area: CGRect
    init(_ area: CGRect) { self.area = area; super.init() }
    override var rect: CGRect { area }
    override var writingDirection: NSWritingDirection { .leftToRight }
    override var containsStart: Bool { true }
    override var containsEnd: Bool { true }
    override var isVertical: Bool { false }
}

@MainActor
extension GhosttyVTView: UITextInput, UITextInputTraits {
    var hasText: Bool { true } // A terminal can always accept Backspace, even with no local preedit.
    var beginningOfDocument: UITextPosition { VTInputPosition(0) }
    var endOfDocument: UITextPosition { VTInputPosition(inputStorage.length) }
    var markedTextRange: UITextRange? {
        inputStorage.isMarked ? VTInputRange(0, inputStorage.length) : nil
    }
    var selectedTextRange: UITextRange? {
        get { VTInputRange(inputStorage.selection.location, NSMaxRange(inputStorage.selection)) }
        set {
            guard let range = validRange(newValue) else { return }
            inputDelegate?.selectionWillChange(self)
            inputStorage.selection = NSRange(location: range.lower, length: range.upper - range.lower)
            inputDelegate?.selectionDidChange(self)
        }
    }

    func insertText(_ text: String) {
        guard isInputFocusAllowed, !text.isEmpty else { return }
        // insertText replaces/commits marked text; a following unmarkText is
        // a no-op because the preedit has already been cleared.
        changePreedit("", selection: .init(location: 0, length: 0), marked: false)
        submitCommittedText(text)
    }

    func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        guard isInputFocusAllowed else { return }
        let text = markedText ?? ""
        changePreedit(text, selection: selectedRange, marked: !text.isEmpty)
    }

    func unmarkText() {
        guard inputStorage.isMarked else { return }
        let committed = inputStorage.text
        cancelComposition()
        if isInputFocusAllowed { submitCommittedText(committed) }
    }

    func cancelComposition() {
        changePreedit("", selection: .init(location: 0, length: 0), marked: false)
    }

    func deleteBackward() {
        guard isInputFocusAllowed else { return }
        guard inputStorage.isMarked else {
            submitKey(.init(key: .backspace, modifiers: inputModifiers))
            return
        }
        let text = inputStorage.text as NSString
        var range = inputStorage.selection
        if range.length == 0 {
            guard range.location > 0 else { return }
            range = text.rangeOfComposedCharacterSequence(at: range.location - 1)
        } else {
            range = text.rangeOfComposedCharacterSequences(for: range)
        }
        let updated = text.replacingCharacters(in: range, with: "")
        changePreedit(updated, selection: .init(location: range.location, length: 0), marked: !updated.isEmpty)
    }

    func text(in range: UITextRange) -> String? {
        guard let range = validRange(range) else { return nil }
        return (inputStorage.text as NSString).substring(with: NSRange(location: range.lower, length: range.upper - range.lower))
    }

    func replace(_ range: UITextRange, withText text: String) {
        guard isInputFocusAllowed, let range = validRange(range) else { return }
        if inputStorage.isMarked {
            let updated = (inputStorage.text as NSString).replacingCharacters(
                in: .init(location: range.lower, length: range.upper - range.lower), with: text)
            changePreedit(updated, selection: .init(location: range.lower + text.utf16.count, length: 0), marked: !updated.isEmpty)
        } else {
            // There is no local document containing remote, committed text.
            // Autocorrection is disabled; UIKit replacement at the empty
            // insertion point is a new commit, not a terminal-screen edit.
            insertText(text)
        }
    }

    func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        guard let a = validPosition(fromPosition), let b = validPosition(toPosition) else { return nil }
        return VTInputRange(a, b)
    }
    func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let index = validPosition(position), offset >= -index, offset <= inputStorage.length - index else { return nil }
        return VTInputPosition(index + offset)
    }
    func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        switch direction {
        case .left: return self.position(from: position, offset: offset == Int.min ? Int.max : -offset)
        case .right: return self.position(from: position, offset: offset)
        case .up: return beginningOfDocument
        case .down: return endOfDocument
        @unknown default: return nil
        }
    }
    func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        let a = (position as? VTInputPosition)?.index ?? 0
        let b = (other as? VTInputPosition)?.index ?? 0
        return a == b ? .orderedSame : a < b ? .orderedAscending : .orderedDescending
    }
    func offset(from: UITextPosition, to: UITextPosition) -> Int {
        ((to as? VTInputPosition)?.index ?? 0) - ((from as? VTInputPosition)?.index ?? 0)
    }
    func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        guard let range = validRange(range) else { return nil }
        return VTInputPosition(direction == .left || direction == .up ? range.lower : range.upper)
    }
    func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        guard let index = validPosition(position) else { return nil }
        let previous = direction == .left || direction == .up
        let target = previous ? index - 1 : index
        guard target >= 0, target < inputStorage.length else { return nil }
        let range = (inputStorage.text as NSString).rangeOfComposedCharacterSequence(at: target)
        return VTInputRange(range.location, NSMaxRange(range))
    }
    func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection { .leftToRight }
    func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {
        // A terminal's logical columns are LTR; writing direction cannot
        // reorder VT cells. CoreText handles glyph shaping in the preedit.
    }
    func firstRect(for range: UITextRange) -> CGRect {
        guard let range = validRange(range) else { return .zero }
        let start = caretRect(for: range.start)
        let end = caretRect(for: range.end)
        return CGRect(x: min(start.minX, end.minX), y: start.minY,
                      width: max(1, abs(end.minX - start.minX)), height: cellSize.height)
    }
    func caretRect(for position: UITextPosition) -> CGRect {
        guard let index = validPosition(position) else { return .zero }
        let cursor = screen.cursor?.position
        let line = compositionLine()
        let offset = CGFloat(CTLineGetOffsetForStringIndex(line, index, nil))
        return CGRect(x: min(max(0, CGFloat(cursor?.column ?? 0) * cellSize.width + offset), max(0, bounds.width - 2)),
                      y: CGFloat(cursor?.row ?? 0) * cellSize.height, width: 2, height: cellSize.height)
    }
    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        guard validRange(range) != nil else { return [] }
        return [VTInputSelectionRect(firstRect(for: range))]
    }
    func closestPosition(to point: CGPoint) -> UITextPosition? {
        let origin = CGFloat(screen.cursor?.position?.column ?? 0) * cellSize.width
        let index = CTLineGetStringIndexForPosition(compositionLine(), CGPoint(x: point.x - origin, y: 0))
        return VTInputPosition(min(max(index == kCFNotFound ? inputStorage.length : index, 0), inputStorage.length))
    }
    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
        guard let range = validRange(range), let index = closestPosition(to: point) as? VTInputPosition else { return nil }
        return VTInputPosition(min(max(index.index, range.lower), range.upper))
    }
    func characterRange(at point: CGPoint) -> UITextRange? {
        guard let position = closestPosition(to: point) else { return nil }
        return characterRange(byExtending: position, in: .right)
    }
    func textStyling(at position: UITextPosition, in direction: UITextStorageDirection) -> [NSAttributedString.Key: Any]? {
        [.font: font, .foregroundColor: screen.theme?.foreground.uiColor ?? UIColor.label]
    }

    private func validPosition(_ position: UITextPosition) -> Int? {
        guard let index = (position as? VTInputPosition)?.index, (0...inputStorage.length).contains(index) else { return nil }
        return index
    }
    private func validRange(_ range: UITextRange?) -> VTInputRange? {
        guard let range = range as? VTInputRange, range.lower >= 0, range.upper <= inputStorage.length else { return nil }
        return range
    }
    private func changePreedit(_ text: String, selection: NSRange, marked: Bool) {
        inputDelegate?.textWillChange(self)
        inputDelegate?.selectionWillChange(self)
        inputStorage.text = text
        let length = text.utf16.count
        let location = min(selection.location, length)
        inputStorage.selection = .init(location: location, length: min(selection.length, length - location))
        inputStorage.isMarked = marked
        onCompositionChange?(marked ? text : nil)
        inputDelegate?.textDidChange(self)
        inputDelegate?.selectionDidChange(self)
    }
    private func compositionLine() -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: inputStorage.text, attributes: [.font: font]))
    }

    var inputModifiers: GhosttyVt.Terminal.Modifiers {
        var modifiers: GhosttyVt.Terminal.Modifiers = []
        if controlModifier { modifiers.insert(.control) }
        if metaModifier { modifiers.insert(.option) }
        return modifiers
    }
    func submitCommittedText(_ text: String) {
        guard !text.isEmpty else { return }
        switch text {
        case "\n", "\r": submitKey(.init(key: .enter, modifiers: inputModifiers))
        case "\t": submitKey(.init(key: .tab, modifiers: inputModifiers))
        default:
            submitKey(.init(text: text, modifiers: inputModifiers,
                            unshiftedCodepoint: text.unicodeScalars.count == 1 ? text.unicodeScalars.first?.value : nil))
        }
    }
    func submitKey(_ key: GhosttyVt.Terminal.KeyEvent) {
        guard isInputFocusAllowed else { return }
        onInput?(.key(key))
        controlModifier = false
        metaModifier = false
        onModifiersConsumed?()
    }
}
