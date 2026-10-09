import SwiftUI

/// The text to translate. A vertical `TextField` rather than a `TextEditor`: only the field draws a
/// system placeholder, which is the one way to have it sit exactly where the caret does -- an
/// overlay on a `TextEditor` has to guess the text view's insets and kept landing beside it.
struct QuickTranslateInput: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    let submit: () -> Void

    /// Tracked so that ⇧Return can put a newline where the caret is: Return itself translates.
    @State private var selection: TextSelection?

    var body: some View {
        ScrollView {
            TextField("Text to translate", text: $text, selection: $selection,
                      prompt: Text("Type text to translate…"), axis: .vertical)
                .textFieldStyle(.plain)
                .labelsHidden()
                .focused(focused)
                .onKeyPress(.return, phases: .down, action: handleReturn)
                .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The field is only as tall as its text; a click in the empty space below still means
        // "type here". Not a control, so a tap gesture rather than a button.
        .contentShape(.rect)
        .onTapGesture { focused.wrappedValue = true }
    }

    private func handleReturn(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers.contains(.shift) {
            insertNewline()
        } else {
            submit()
        }
        return .handled
    }

    private func insertNewline() {
        // The selection can trail the text by an edit, so its indices are clamped through UTF-16
        // offsets instead of being used on `text` directly.
        let length = text.utf16.count
        var lower = length
        var upper = length
        if case .selection(let selected) = selection?.indices {
            lower = min(selected.lowerBound.utf16Offset(in: text), length)
            upper = min(max(selected.upperBound.utf16Offset(in: text), lower), length)
        }
        let start = String.Index(utf16Offset: lower, in: text)
        let end = String.Index(utf16Offset: upper, in: text)
        text.replaceSubrange(start..<end, with: "\n")
        selection = TextSelection(insertionPoint: String.Index(utf16Offset: lower + 1, in: text))
    }
}
