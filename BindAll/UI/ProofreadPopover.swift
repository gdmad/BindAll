import AppKit
import SwiftUI

/// The small floating list of fixes shown under a problem word.
///
/// Like `AutocompleteOverlay`, this must never take focus: the user's text field stays key so the
/// selection stays visible and the fix lands where they are typing. So: non-activating panel,
/// `orderFront` rather than `makeKey`, and no `NSApp.activate` anywhere. The chrome, the cells and
/// the placement come from `PopupKit`, shared with the autocomplete popup.
@MainActor
final class ProofreadPopover {
    private var panel: NSPanel?
    /// How many fixes the last tile presentation put on its first row (0 = not a tile / even split).
    /// The controller reads it so vertical arrow navigation jumps by the real column count.
    private(set) var lastTileTopCount = 0

    /// Shows `issue`'s fixes with `selected` highlighted, placed above `anchor` -- the word's rect in
    /// AppKit screen coordinates. `onHover`/`onAccept` receive the row index the mouse is on.
    func show(issue: TextIssue, selected: Int, position: String, anchor: CGRect, layout: PopupLayout,
              fontSize: CGFloat, onHover: @escaping (Int) -> Void, onAccept: @escaping (Int) -> Void) {
        let topCount = layout == .tile
            ? PopupTile.topRowCount(for: issue.replacements, fontSize: fontSize,
                                    near: NSPoint(x: anchor.minX, y: anchor.maxY))
            : 0
        lastTileTopCount = topCount
        let view = PopoverView(title: issue.shortMessage.isEmpty ? issue.message : issue.shortMessage,
                               kind: issue.kind,
                               replacements: issue.replacements,
                               selected: selected,
                               layout: layout,
                               tileTopCount: topCount,
                               position: position,
                               fontSize: fontSize,
                               onHover: onHover,
                               onAccept: onAccept)
        present(AnyView(view), above: anchor)
    }

    /// A one-line notice (checking, no issues, server error) in the same place as the list.
    func showMessage(_ text: String, anchor: CGRect, fontSize: CGFloat, spinner: Bool = false) {
        lastTileTopCount = 0
        present(AnyView(MessageView(text: text, fontSize: fontSize, spinner: spinner)), above: anchor)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func present(_ view: AnyView, above anchor: CGRect) {
        let host = FirstMouseHostingView(rootView: view)
        let panel = self.panel ?? makePanel()
        panel.contentView = host
        panel.layoutIfNeeded()
        let size = host.fittingSize
        panel.setContentSize(size)
        panel.setFrameOrigin(PopupPlacement.origin(above: anchor, size: size))
        panel.orderFront(nil) // NOT makeKey: the text field must keep focus.
    }

    private func makePanel() -> NSPanel {
        let panel = PopupPanel.make(ignoresMouseEvents: false) // rows accept hover and click-to-apply
        self.panel = panel
        return panel
    }
}

/// The panel is never key, so any click on it is a "first mouse"; accept it so a single click on a
/// row applies the fix instead of just trying (and failing) to focus the panel.
private final class FirstMouseHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Views

private struct PopoverView: View {
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
            header
            if replacements.isEmpty {
                Text("No suggestions for this word")
                    .font(.system(size: fontSize - 1))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, PopupMetrics.cellPaddingH)
            } else {
                fixes
            }
        }
        .frame(minWidth: PopupMetrics.minWidth, maxWidth: PopupMetrics.maxWidth, alignment: .leading)
        .popupChrome()
    }

    /// The kind marker, the rule's own wording, and where this word sits among the problems found.
    /// With "Differentiate Without Color" on, the marker becomes a symbol: the kind must not be
    /// carried by a colored dot alone.
    private var header: some View {
        HStack(spacing: 5) {
            if PopupAppearance.differentiateWithoutColor {
                Image(systemName: IssueKindStyle.symbolName(kind))
                    .font(.system(size: fontSize - 3))
                    .foregroundStyle(IssueKindStyle.color(kind))
            } else {
                Circle().fill(IssueKindStyle.color(kind)).frame(width: 6, height: 6)
            }
            Text(title)
                .font(.system(size: fontSize - 2))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text(position)
                .font(.system(size: fontSize - 3))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, PopupMetrics.cellPaddingH)
    }

    /// The fixes in the chosen layout: full-width rows in a column, compact cells in a line, and a
    /// two-row grid in the tile. The tile's split is measured, like the autocomplete popup's, and it
    /// is the same number arrow navigation steps by. Both tile rows start at the leading edge -- a
    /// shorter second row must not be centered.
    private var fixes: some View {
        Group {
            switch layout {
            case .column:
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(replacementIndices, id: \.self) { cell($0, fillsWidth: true) }
                }
            case .line:
                HStack(spacing: PopupMetrics.cellSpacing) {
                    ForEach(replacementIndices, id: \.self) { cell($0) }
                }
            case .tile:
                let topCount = tileTopCount > 0 ? tileTopCount : PopupLayout.tileColumns(forCount: replacements.count)
                let top = Array(replacementIndices.prefix(topCount))
                let bottom = Array(replacementIndices.dropFirst(topCount))
                VStack(alignment: .leading, spacing: PopupMetrics.cellSpacing) {
                    HStack(spacing: PopupMetrics.cellSpacing) { ForEach(top, id: \.self) { cell($0) } }
                    if !bottom.isEmpty {
                        HStack(spacing: PopupMetrics.cellSpacing) { ForEach(bottom, id: \.self) { cell($0) } }
                    }
                }
            }
        }
    }

    private var replacementIndices: [Int] { Array(replacements.indices) }

    private func cell(_ index: Int, fillsWidth: Bool = false) -> some View {
        PopupCell(text: replacements[index], isSelected: index == selected, fontSize: fontSize,
                  fillsWidth: fillsWidth)
            .onTapGesture { onAccept(index) }
            // The guard avoids a hover -> re-render -> hover feedback loop.
            .onHover { inside in if inside && index != selected { onHover(index) } }
    }
}

private struct MessageView: View {
    let text: String
    let fontSize: CGFloat
    let spinner: Bool

    var body: some View {
        HStack(spacing: 6) {
            if spinner { ProgressView().controlSize(.small).scaleEffect(0.6) }
            Text(text)
                .font(.system(size: fontSize - 1))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .popupChrome()
    }
}
