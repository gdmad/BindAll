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

/// Wraps a binding so writes land one runloop tick later. Text fields commit their text when they
/// lose focus, and during a settings tab switch that happens inside the view update — writing a
/// @Published-backed binding there logs "Publishing changes from within view updates". Use for any
/// TextField/TextEditor bound to `appState.settings`.
///
/// **Text fields only.** A Picker writes from a user action, not from a view update, so it needs no
/// deferral -- and it re-reads its selection immediately, sees the value it just set still missing,
/// and snaps back to the old one, which is how the layout pickers were losing every choice.
func deferredWrite<T>(_ source: Binding<T>) -> Binding<T> {
    Binding(get: { source.wrappedValue },
            set: { value in DispatchQueue.main.async { source.wrappedValue = value } })
}

extension View {
    /// Neutral dark box for a text field/editor (use with .textFieldStyle(.plain) and labelsHidden).
    func darkField() -> some View { modifier(DarkFieldStyle()) }

    /// Apply to a tab's root so it does not auto-focus a text field on appear.
    func clearFocusOnAppear() -> some View { modifier(ClearFocusOnAppear()) }
}
