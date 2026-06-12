import SwiftUI
import AppKit

extension Color {
    /// Neutral input-box fill: recessed in dark mode, a subtle gray in light mode.
    static func fieldFill(for scheme: ColorScheme) -> Color {
        Color.black.opacity(scheme == .dark ? 0.28 : 0.06)
    }
}

/// A neutral input box. Apply to the field only (e.g. inside LabeledContent) so the row's
/// label stays outside the box.
struct DarkFieldStyle: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.fieldFill(for: colorScheme)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}

/// Clears the keyboard focus shortly after a view appears, so switching settings tabs does not drop
/// the caret into the first text field.
struct ClearFocusOnAppear: ViewModifier {
    func body(content: Content) -> some View {
        content.onAppear {
            DispatchQueue.main.async {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
    }
}

extension View {
    /// Neutral dark box for a text field/editor (use with .textFieldStyle(.plain) and labelsHidden).
    func darkField() -> some View { modifier(DarkFieldStyle()) }

    /// Apply to a tab's root so it does not auto-focus a text field on appear.
    func clearFocusOnAppear() -> some View { modifier(ClearFocusOnAppear()) }
}
