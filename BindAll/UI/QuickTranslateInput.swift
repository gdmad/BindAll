import SwiftUI

struct QuickTranslateInput: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    let submit: () -> Void

    /// Where `TextEditor` draws its first character: the padding below plus the text view's own
    /// line-fragment padding. The placeholder sits exactly there, level with the caret.
    private static let inset: CGFloat = 8
    private static let lineFragmentPadding: CGFloat = 5

    var body: some View {
        TextEditor(text: $text)
            .scrollContentBackground(.hidden)
            .padding(Self.inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .focused(focused)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Type text to translate…")
                        .foregroundStyle(.secondary)
                        .padding(.leading, Self.inset + Self.lineFragmentPadding)
                        .padding(.top, Self.inset)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .onKeyPress(keys: [.return]) { press in
                if press.modifiers.contains(.shift) { return .ignored }
                submit()
                return .handled
            }
    }
}
