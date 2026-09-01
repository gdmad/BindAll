import Foundation

/// Splits a popup's items across the two rows of the tile layout.
///
/// Both popups use it, so a tile looks and navigates the same whether it holds completions or fixes:
/// the number it returns is what the view draws AND what arrow navigation steps by.
enum PopupTilePacker {
    /// How many of `widths` (measured cell widths in points, in display order) fit on the first row.
    ///
    /// Cells are packed left to right until the next one would overflow `maxContent`, so every item
    /// that fits stays on the first row. A single item wider than the row still gets that row to
    /// itself -- a word is never dropped just because it cannot fit anywhere.
    static func topRowCount(widths: [CGFloat], spacing: CGFloat, maxContent: CGFloat) -> Int {
        guard widths.count > 1 else { return widths.count }
        var used: CGFloat = 0
        var count = 0
        for width in widths {
            let needed = width + (count > 0 ? spacing : 0)
            if count > 0, used + needed > maxContent { break }
            used += needed
            count += 1
        }
        return max(1, count)
    }
}
