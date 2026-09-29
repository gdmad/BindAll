import SwiftUI

/// One item of either popup. The font weight never changes and the cell never scales, so the panel
/// keeps its size as the selection moves.
struct PopupCell: View {
    let text: String
    let isSelected: Bool
    let fontSize: CGFloat
    /// Column layouts stretch their cells so the selection pill spans the whole row.
    var fillsWidth = false
    /// What a click on the cell does. Nil for a cell that is not clickable (the autocomplete list is
    /// purely keyboard-driven), which is also what keeps it from being announced as a button.
    var onActivate: (() -> Void)?

    var body: some View {
        Text(text)
            .font(.system(size: fontSize))
            .foregroundStyle(isSelected ? Color(nsColor: .selectedMenuItemTextColor) : Color.primary)
            .padding(.horizontal, PopupMetrics.cellPaddingH)
            .padding(.vertical, PopupMetrics.cellPaddingV)
            .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
            .background(isSelected ? Color(nsColor: .selectedContentBackgroundColor) : Color.clear,
                        in: RoundedRectangle(cornerRadius: PopupMetrics.cellRadius))
            .contentShape(Rectangle())
            // A tap gesture rather than a Button: the panel is non-activating and never key, and
            // applying the fix on a click is the popup's main job -- not worth risking on a control
            // whose behaviour in such a panel cannot be checked here. The traits and the action
            // below give assistive tech what a Button would have.
            .onTapGesture { onActivate?() }
            .accessibilityAddTraits(traits)
            .accessibilityActions {
                if let onActivate { Button(text, action: onActivate) }
            }
    }

    private var traits: AccessibilityTraits {
        let selection: AccessibilityTraits = isSelected ? .isSelected : []
        let button: AccessibilityTraits = onActivate == nil ? [] : .isButton
        return selection.union(button)
    }
}
