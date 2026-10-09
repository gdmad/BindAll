import SwiftUI

/// Clears the keyboard focus right after a view appears, so switching settings tabs does not drop
/// the caret into the first text field.
struct ClearFocusOnAppear: ViewModifier {
    func body(content: Content) -> some View {
        content.task {
            // After the window has picked its own first responder, which happens on appear.
            await Task.yield()
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }
}

extension View {
    /// Apply to a tab's root so it does not auto-focus a text field on appear.
    func clearFocusOnAppear() -> some View { modifier(ClearFocusOnAppear()) }
}
