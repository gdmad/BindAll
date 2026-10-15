import SwiftUI

/// The popup's top line: what is wrong and where this word sits among the problems found, then the
/// Skip button.
struct FixesPopupHeader: View {
    let title: String
    let kind: IssueKind
    /// e.g. "2 of 7"
    let position: String
    let fontSize: CGFloat
    let skipSelected: Bool
    let onHoverSkip: () -> Void
    let onSkip: () -> Void

    var body: some View {
        HStack(spacing: PopupMetrics.inlineSpacing) {
            FixesPopupSummary(title: title, kind: kind, position: position, fontSize: fontSize)
            FixesPopupSkipButton(isSelected: skipSelected, fontSize: fontSize,
                                 onHover: onHoverSkip, onActivate: onSkip)
        }
    }
}
