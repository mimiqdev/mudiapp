import UIKit

struct TerminalCompositionState: Equatable, Sendable {
    private(set) var visibleText: String?

    mutating func update(markedText: String?) {
        visibleText = markedText?.isEmpty == false ? markedText : nil
    }
}

@MainActor
final class TerminalCompositionInputDelegate: NSObject, UITextInputDelegate {
    weak var downstream: UITextInputDelegate?
    var onTextChange: ((UITextInput) -> Void)?

    func selectionWillChange(_ textInput: UITextInput?) {
        downstream?.selectionWillChange(textInput)
    }

    func selectionDidChange(_ textInput: UITextInput?) {
        downstream?.selectionDidChange(textInput)
    }

    func textWillChange(_ textInput: UITextInput?) {
        downstream?.textWillChange(textInput)
    }

    func textDidChange(_ textInput: UITextInput?) {
        downstream?.textDidChange(textInput)
        if let textInput {
            onTextChange?(textInput)
        }
    }

    @available(iOS 18.4, *)
    func conversationContext(_ context: UIConversationContext?, didChange textInput: UITextInput?) {
        downstream?.conversationContext(context, didChange: textInput)
    }
}
