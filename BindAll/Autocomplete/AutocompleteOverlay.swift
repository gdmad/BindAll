import AppKit
import SwiftUI

/// A tiny, non-activating floating list of completion candidates near the caret. It never becomes the
/// key window, so it does not steal focus from the text field being typed into.
///
/// The chrome, the cells, the layouts and the placement come from `PopupKit`, shared with the
/// proofread popup; the panel itself is `PopupPresenter`'s.
final class AutocompleteOverlay {
    private let presenter = PopupPresenter(ignoresMouseEvents: true) // purely keyboard-driven
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
        let list = PopupItemsLayout(items: items, selected: selected, layout: layout,
                                    fontSize: fontSize, tileTopCount: topCount)
            .popupChrome()
        presenter.present(list) { PopupPlacement.origin(below: anchor, size: $0) }
    }

    func hide() {
        presenter.hide()
    }
}
