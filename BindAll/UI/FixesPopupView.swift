import SwiftUI

/// The proofread popup: the issue's header and its fixes in the chosen layout.
struct FixesPopupView: View {
    let title: String
    let kind: IssueKind
    let replacements: [String]
    let selected: Int
    let layout: PopupLayout
    /// Fixes on the first row of a tile, measured in `ProofreadPopover.show()`; 0 = even split.
    let tileTopCount: Int
    /// e.g. "2 of 7"
    let position: String
    /// Base size for the fix rows; the header sits a couple of points below it.
    let fontSize: CGFloat
    let onHover: (Int) -> Void
    let onAccept: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PopupMetrics.cellSpacing) {
            FixesPopupHeader(title: title, kind: kind, position: position, fontSize: fontSize)
            if replacements.isEmpty {
                // Real information, not a hint: secondary rather than tertiary, which is hard to read
                // on the material.
                Text("No suggestions for this word")
                    .font(.system(size: PopupMetrics.secondaryFontSize(fontSize)))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, PopupMetrics.cellPaddingH)
            } else {
                PopupItemsLayout(items: replacements, selected: selected, layout: layout,
                                 fontSize: fontSize, tileTopCount: tileTopCount,
                                 onHover: onHover, onActivate: onAccept)
            }
            Divider()
            FixesPopupSkipRow(isSelected: selected == skipIndex, fontSize: fontSize,
                              onHover: hoverSkip, onActivate: skip)
        }
        .frame(minWidth: PopupMetrics.minWidth, maxWidth: PopupMetrics.maxWidth, alignment: .leading)
        .popupChrome()
    }

    /// The Skip row follows the fixes, so its index is the number of fixes.
    private var skipIndex: Int { replacements.count }

    private func hoverSkip() {
        onHover(skipIndex)
    }

    private func skip() {
        onAccept(skipIndex)
    }
}
