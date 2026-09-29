import SwiftUI

/// The items of either popup in the chosen layout: full-width rows in a column, compact cells in a
/// line, and a two-row grid in the tile. One implementation for both popups -- they used to carry
/// their own copies, which had already drifted apart (row spacing of 1 pt against 2 pt).
///
/// The tile's split is measured by the caller and is the same number arrow navigation steps by, so
/// what the user sees is what up/down move across. Both tile rows start at the leading edge: a shorter
/// second row must not be centered.
struct PopupItemsLayout: View {
    let items: [String]
    let selected: Int
    let layout: PopupLayout
    let fontSize: CGFloat
    /// Items on the first row of a tile, measured in `PopupTile.topRowCount`; 0 = even split.
    var tileTopCount = 0
    /// Mouse moved onto an item. Nil for the keyboard-only autocomplete list.
    var onHover: ((Int) -> Void)?
    /// Item clicked. Nil for the keyboard-only autocomplete list.
    var onActivate: ((Int) -> Void)?

    var body: some View {
        switch layout {
        case .column:
            VStack(alignment: .leading, spacing: PopupMetrics.columnSpacing) {
                ForEach(items.indices, id: \.self) { cell($0, fillsWidth: true) }
            }
        case .line:
            HStack(spacing: PopupMetrics.cellSpacing) {
                ForEach(items.indices, id: \.self) { cell($0) }
            }
        case .tile:
            let firstRow = min(tileTopCount > 0 ? tileTopCount : PopupLayout.tileColumns(forCount: items.count),
                               items.count)
            VStack(alignment: .leading, spacing: PopupMetrics.cellSpacing) {
                HStack(spacing: PopupMetrics.cellSpacing) {
                    ForEach(0..<firstRow, id: \.self) { cell($0) }
                }
                if firstRow < items.count {
                    HStack(spacing: PopupMetrics.cellSpacing) {
                        ForEach(firstRow..<items.count, id: \.self) { cell($0) }
                    }
                }
            }
        }
    }

    private func cell(_ index: Int, fillsWidth: Bool = false) -> some View {
        PopupCell(text: items[index], isSelected: index == selected, fontSize: fontSize,
                  fillsWidth: fillsWidth, onActivate: onActivate.map { activate in { activate(index) } })
            // The guard avoids a hover -> re-render -> hover feedback loop.
            .onHover { inside in if inside && index != selected { onHover?(index) } }
    }
}
