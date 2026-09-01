import AppKit
import SwiftUI

/// The shared look and mechanics of the two floating popups: autocomplete suggestions and proofread
/// fixes. They are different lists, but to the user they are one thing -- a small list that appears
/// next to the caret -- so geometry, selection and placement live here rather than in each popup.
///
/// The look follows a system menu: a material panel with a hairline border and the standard blue
/// selection pill. Nothing scales or animates on selection; a menu does not move under the pointer,
/// and the popup sits over text the user is reading.
enum PopupMetrics {
    static let containerPadding: CGFloat = 6
    static let containerRadius: CGFloat = 8
    static let cellRadius: CGFloat = 5
    static let cellPaddingH: CGFloat = 7
    static let cellPaddingV: CGFloat = 3
    /// Between cells in a row, and between the two rows of a tile.
    static let cellSpacing: CGFloat = 4
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
}

/// Accessibility settings both popups honour. Read at presentation time: the popups are rebuilt on
/// every selection move, so a change in System Settings takes effect on the next keystroke.
enum PopupAppearance {
    static var reduceTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    static var differentiateWithoutColor: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldDifferentiateWithoutColor
    }
}

// MARK: - Views

/// Panel background, border and padding, shared by both popups.
struct PopupChromeModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(PopupMetrics.containerPadding)
            .background(background)
            .overlay(
                RoundedRectangle(cornerRadius: PopupMetrics.containerRadius)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            )
            .fixedSize()
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: PopupMetrics.containerRadius)
        if PopupAppearance.reduceTransparency {
            shape.fill(Color(nsColor: .windowBackgroundColor))
        } else {
            shape.fill(.regularMaterial)
        }
    }
}

extension View {
    func popupChrome() -> some View { modifier(PopupChromeModifier()) }
}

/// One item of either popup. The font weight never changes and the cell never scales, so the panel
/// keeps its size as the selection moves.
struct PopupCell: View {
    let text: String
    let isSelected: Bool
    let fontSize: CGFloat
    /// Column layouts stretch their cells so the selection pill spans the whole row.
    var fillsWidth = false

    var body: some View {
        Text(text)
            .font(.system(size: fontSize))
            .foregroundStyle(isSelected ? Color(nsColor: .selectedMenuItemTextColor) : Color.primary)
            .padding(.horizontal, PopupMetrics.cellPaddingH)
            .padding(.vertical, PopupMetrics.cellPaddingV)
            .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
            .background(isSelected ? Color(nsColor: .selectedContentBackgroundColor) : Color.clear,
                        in: RoundedRectangle(cornerRadius: PopupMetrics.cellRadius))
            .contentShape(Rectangle())
    }
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
