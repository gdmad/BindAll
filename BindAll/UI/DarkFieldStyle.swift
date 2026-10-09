import SwiftUI

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
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator, lineWidth: 1))
    }
}

extension View {
    /// Neutral dark box for a text field/editor (use with .textFieldStyle(.plain) and labelsHidden).
    func darkField() -> some View { modifier(DarkFieldStyle()) }
}
