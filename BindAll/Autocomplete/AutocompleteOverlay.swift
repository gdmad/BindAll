import AppKit
import SwiftUI

/// A tiny, non-activating floating list of completion candidates near the caret. It never becomes the
/// key window, so it does not steal focus from the text field being typed into.
///
/// The chrome, the cells and the placement come from `PopupKit`, shared with the proofread popup.
final class AutocompleteOverlay {
    private var panel: NSPanel?
    /// How many items the last tile presentation put on its first row (0 = not a tile / even split).
    /// The controller reads this so vertical arrow navigation jumps by the real column count.
    private(set) var lastTileTopCount = 0

    /// Shows `items` (with `selected` highlighted) anchored to `anchor` (the caret's rect in AppKit
    /// screen coordinates, bottom-left origin). `layout` arranges them in a column, a single line, or
    /// a two-row tile. Normally hangs below `anchor`; rises above it instead when the field sits too
    /// low on screen for the list to fit underneath.
    func show(_ items: [String], selected: Int, layout: PopupLayout, fontSize: CGFloat, anchor: CGRect) {
        let topCount = layout == .tile
            ? PopupTile.topRowCount(for: items, fontSize: fontSize, near: anchor.origin) : 0
        lastTileTopCount = topCount
        let host = NSHostingController(rootView: ListView(items: items, selected: selected,
                                                          layout: layout, fontSize: fontSize,
                                                          tileTopCount: topCount))
        let panel = self.panel ?? makePanel()
        panel.contentViewController = host
        panel.layoutIfNeeded()
        let size = host.view.fittingSize
        panel.setContentSize(size)
        panel.setFrameOrigin(PopupPlacement.origin(below: anchor, size: size))
        panel.orderFront(nil) // NOT makeKey: must not take focus from the text field.
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = PopupPanel.make(ignoresMouseEvents: true) // purely keyboard-driven
        self.panel = panel
        return panel
    }
}

private struct ListView: View {
    let items: [String]
    let selected: Int
    let layout: PopupLayout
    let fontSize: CGFloat
    /// Items on the first row of a tile, measured in `AutocompleteOverlay.show()`; 0 = even split.
    var tileTopCount = 0

    var body: some View {
        Group {
            switch layout {
            case .column:
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(itemIndices, id: \.self) { cell($0, fillsWidth: true) }
                }
            case .line:
                HStack(spacing: PopupMetrics.cellSpacing) {
                    ForEach(itemIndices, id: \.self) { cell($0) }
                }
            case .tile:
                // Two rows, filled left to right. The split is measured in show(), so every word
                // that fits stays on the first row. Both rows start at the leading edge.
                let topCount = tileTopCount > 0 ? tileTopCount : PopupLayout.tileColumns(forCount: items.count)
                let topRow = Array(items.indices.prefix(topCount))
                let bottomRow = Array(items.indices.dropFirst(topCount))
                VStack(alignment: .leading, spacing: PopupMetrics.cellSpacing) {
                    HStack(spacing: PopupMetrics.cellSpacing) { ForEach(topRow, id: \.self) { cell($0) } }
                    if !bottomRow.isEmpty {
                        HStack(spacing: PopupMetrics.cellSpacing) { ForEach(bottomRow, id: \.self) { cell($0) } }
                    }
                }
            }
        }
        .popupChrome()
    }

    private var itemIndices: [Int] { Array(items.indices) }

    private func cell(_ index: Int, fillsWidth: Bool = false) -> some View {
        PopupCell(text: items[index], isSelected: index == selected, fontSize: fontSize,
                  fillsWidth: fillsWidth)
    }
}
