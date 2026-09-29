import AppKit
import SwiftUI

/// The shared look and mechanics of the two floating popups: autocomplete suggestions and proofread
/// fixes. They are different lists, but to the user they are one thing -- a small list that appears
/// next to the caret -- so geometry, selection and placement live here rather than in each popup.
/// The views themselves are in `PopupChrome`, `PopupCell` and `PopupItemsLayout`; the panel is
/// `PopupPresenter`'s.
///
/// The look follows a system menu: a material panel with a hairline border and the standard blue
/// selection pill. Nothing scales or animates on selection; a menu does not move under the pointer,
/// and the popup sits over text the user is reading.
enum PopupMetrics {
    static let containerPadding: CGFloat = 6
    static let cellRadius: CGFloat = 5
    /// Concentric with the cells: an inner radius plus the padding around it is the outer radius, so
    /// the selection pill's corners run parallel to the panel's instead of fighting them.
    static let containerRadius: CGFloat = cellRadius + containerPadding
    static let cellPaddingH: CGFloat = 7
    static let cellPaddingV: CGFloat = 3
    /// Between cells in a row, and between the two rows of a tile.
    static let cellSpacing: CGFloat = 4
    /// Between the rows of a column.
    static let columnSpacing: CGFloat = 2
    /// Between the small parts of a single line (marker, text, spinner).
    static let inlineSpacing: CGFloat = 5
    static let maxWidth: CGFloat = 480
    static let minWidth: CGFloat = 150
    /// Kept clear of the screen edges.
    static let screenInset: CGFloat = 4
    /// Gap between the popup and the word it belongs to.
    static let anchorGap: CGFloat = 6
    /// What a cell adds around its text: the horizontal padding plus a point of slack.
    static let cellChrome: CGFloat = cellPaddingH * 2 + 2

    /// Widest the content may get near `screen`, used when packing the tile's first row.
    static func maxContentWidth(on screen: NSScreen?) -> CGFloat {
        let available = (screen?.visibleFrame.width ?? maxWidth) - 80
        return min(max(minWidth, available), maxWidth) - containerPadding * 2
    }

    // The sizes below hang off the user's own text-size setting (Settings -> General, 10-20 pt), which
    // is why they are numbers and not semantic styles: `PopupTile` measures with the same numbers to
    // pack the tile, and macOS has no Dynamic Type to follow. The floors stop the small text from
    // collapsing to 7 pt when the setting is at its minimum.

    /// The rule's wording in the proofread header.
    static func headerFontSize(_ base: CGFloat) -> CGFloat { max(11, base - 2) }
    /// The "2 of 7" counter and the kind symbol.
    static func counterFontSize(_ base: CGFloat) -> CGFloat { max(10, base - 3) }
    /// Notices and the empty state.
    static func secondaryFontSize(_ base: CGFloat) -> CGFloat { max(10, base - 1) }
}

// MARK: - Panel

enum PopupPanel {
    /// A borderless panel that never becomes key, so the user's text field keeps focus and the
    /// caret stays where they are typing. Autocomplete ignores mouse events entirely; the proofread
    /// popup accepts them, because its rows can be clicked.
    static func make(ignoresMouseEvents: Bool) -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.ignoresMouseEvents = ignoresMouseEvents
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        return panel
    }
}

// MARK: - Placement

enum PopupPlacement {
    /// The screen holding `point`. Both popups pick their screen the same way, so a caret and a
    /// problem word on the same display never place their popups on different ones.
    static func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }

    private static func origin(anchor: CGRect, size: NSSize, preferAbove: Bool) -> NSPoint {
        let probe = NSPoint(x: anchor.midX, y: anchor.midY)
        let visible = screen(containing: probe)?.visibleFrame ?? .zero
        let inset = PopupMetrics.screenInset
        let above = anchor.maxY + PopupMetrics.anchorGap
        let below = anchor.minY - PopupMetrics.anchorGap - size.height
        let aboveFits = above + size.height <= visible.maxY - inset
        let belowFits = below >= visible.minY + inset
        let useAbove = preferAbove ? (aboveFits || !belowFits) : !(belowFits || !aboveFits)
        return clamp(NSPoint(x: anchor.minX, y: useAbove ? above : below), size: size, near: probe)
    }

    /// Sits above `anchor` so the popup never covers the word it is about; drops below it only when
    /// there is no room above (a problem word on the top line of the screen).
    static func origin(above anchor: CGRect, size: NSSize) -> NSPoint {
        origin(anchor: anchor, size: size, preferAbove: true)
    }

    /// Hangs below `anchor` -- where a completion list belongs -- but rises above it when the field
    /// sits too low on screen for the list to fit underneath (a short chat compose box).
    static func origin(below anchor: CGRect, size: NSSize) -> NSPoint {
        origin(anchor: anchor, size: size, preferAbove: false)
    }

    /// Keeps the popup fully on the screen holding `anchor`.
    static func clamp(_ origin: NSPoint, size: NSSize, near anchor: NSPoint) -> NSPoint {
        guard let screen = screen(containing: anchor) else { return origin }
        let v = screen.visibleFrame
        let i = PopupMetrics.screenInset
        return NSPoint(x: min(max(origin.x, v.minX + i), max(v.minX + i, v.maxX - size.width - i)),
                       y: min(max(origin.y, v.minY + i), max(v.minY + i, v.maxY - size.height - i)))
    }
}

// MARK: - Tile packing

enum PopupTile {
    /// How many of `items` go on the tile's first row, measured with the font the cells use. The
    /// same number drives the view and the arrow navigation, so what the user sees is what ↑/↓ step
    /// by. See `PopupTilePacker` for the packing itself.
    static func topRowCount(for items: [String], fontSize: CGFloat, near point: NSPoint) -> Int {
        let font = NSFont.systemFont(ofSize: fontSize)
        let widths = items.map {
            ceil(($0 as NSString).size(withAttributes: [.font: font]).width) + PopupMetrics.cellChrome
        }
        return PopupTilePacker.topRowCount(widths: widths, spacing: PopupMetrics.cellSpacing,
                                           maxContent: PopupMetrics.maxContentWidth(on: screen(near: point)))
    }

    private static func screen(near point: NSPoint) -> NSScreen? {
        PopupPlacement.screen(containing: NSPoint(x: point.x, y: point.y + 10))
    }
}
