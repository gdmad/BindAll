import SwiftUI

/// Wraps a binding so writes land after the current view update. Text fields commit their text when
/// they lose focus, and during a settings tab switch that happens inside the view update. With the
/// old `ObservableObject` model that logged "Publishing changes from within view updates"; the
/// `@Observable` one does not, so this is a candidate for removal once that is confirmed in use.
/// Use for any TextField/TextEditor bound to `appState.settings`.
///
/// **Text fields only.** A Picker writes from a user action, not from a view update, so it needs no
/// deferral -- and it re-reads its selection immediately, sees the value it just set still missing,
/// and snaps back to the old one, which is how the layout pickers were losing every choice.
@MainActor
func deferredWrite<T>(_ source: Binding<T>) -> Binding<T> {
    Binding(get: { source.wrappedValue },
            set: { value in Task { @MainActor in source.wrappedValue = value } })
}
