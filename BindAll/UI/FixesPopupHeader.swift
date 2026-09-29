import SwiftUI

/// The kind marker, the rule's own wording, and where this word sits among the problems found.
///
/// With "Differentiate Without Color" on, the marker becomes a symbol: the kind must not be carried
/// by a colored dot alone. For assistive tech the whole header is one element that names the kind in
/// words, so the dot never has to be interpreted at all.
struct FixesPopupHeader: View {
    let title: String
    let kind: IssueKind
    /// e.g. "2 of 7"
    let position: String
    let fontSize: CGFloat

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        HStack(spacing: PopupMetrics.inlineSpacing) {
            if differentiateWithoutColor {
                Image(systemName: IssueKindStyle.symbolName(kind))
                    .font(.system(size: PopupMetrics.counterFontSize(fontSize)))
                    .foregroundStyle(IssueKindStyle.color(kind))
            } else {
                Circle().fill(IssueKindStyle.color(kind)).frame(width: 6, height: 6)
            }
            Text(title)
                .font(.system(size: PopupMetrics.headerFontSize(fontSize)))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 12)
            // Digits of equal width, so the header does not jiggle as Tab steps through the issues.
            Text(position)
                .font(.system(size: PopupMetrics.counterFontSize(fontSize)))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, PopupMetrics.cellPaddingH)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(IssueKindStyle.title(kind)): \(title)")
        .accessibilityValue(position)
    }
}
