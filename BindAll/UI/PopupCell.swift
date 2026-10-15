import SwiftUI

/// One item of either popup. The font weight never changes and the cell never scales, so the panel
/// keeps its size as the selection moves.
struct PopupCell: View {
    let text: String
    let isSelected: Bool
    let fontSize: CGFloat
    /// Column layouts stretch their cells so the selection pill spans the whole row.
    var fillsWidth = false
    /// A leading symbol, for a cell that is an action rather than a word (proofread's "Skip").
    var systemImage: String?
    /// Secondary text for such an action, so it never reads as one of the fixes.
    var isSecondary = false
    /// False for an icon-only action; `text` then remains its name for VoiceOver.
    var showsTitle = true
    /// What a click on the cell does. Nil for a cell that is not clickable (the autocomplete list is
    /// purely keyboard-driven), which is also what keeps it from being announced as a button.
    var onActivate: (() -> Void)?

    var body: some View {
        Label {
            Text(text)
        } icon: {
            if let systemImage {
                Image(systemName: systemImage).accessibilityHidden(true)
            }
        }
        .labelStyle(PopupCellLabelStyle(showsIcon: systemImage != nil, showsTitle: showsTitle))
        .font(.system(size: fontSize))
        .foregroundStyle(foreground)
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

    private var foreground: AnyShapeStyle {
        if isSelected { AnyShapeStyle(Color(nsColor: .selectedMenuItemTextColor)) }
        else if isSecondary { AnyShapeStyle(.secondary) }
        else { AnyShapeStyle(.primary) }
    }

    private var traits: AccessibilityTraits {
        let selection: AccessibilityTraits = isSelected ? .isSelected : []
        let button: AccessibilityTraits = onActivate == nil ? [] : .isButton
        return selection.union(button)
    }
}

/// Title only for words; icon and title for actions.
private struct PopupCellLabelStyle: LabelStyle {
    let showsIcon: Bool
    let showsTitle: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: PopupMetrics.inlineSpacing) {
            if showsIcon { configuration.icon }
            if showsTitle { configuration.title }
        }
    }
}
