import SwiftUI

/// "Skip": leaves this one place alone. An action, not a fix, so it sits below a divider, in the
/// secondary style and with a symbol -- distinct from the fixes without relying on color.
struct FixesPopupSkipRow: View {
    let isSelected: Bool
    let fontSize: CGFloat
    let onHover: () -> Void
    let onActivate: () -> Void

    var body: some View {
        PopupCell(text: "Skip", isSelected: isSelected, fontSize: fontSize, fillsWidth: true,
                  systemImage: "eye.slash", isSecondary: true, onActivate: onActivate)
            .onHover { inside in if inside && !isSelected { onHover() } }
            .accessibilityLabel("Skip this issue")
    }
}
