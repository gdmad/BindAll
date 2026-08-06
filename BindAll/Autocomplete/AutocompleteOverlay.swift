import AppKit
import SwiftUI

/// A tiny, non-activating floating list of completion candidates near the caret. It never becomes the
/// key window, so it does not steal focus from the text field being typed into.
final class AutocompleteOverlay {
    private var panel: NSPanel?
    /// How many items the last tile presentation put on its first row (0 = not a tile / even split).
    /// The controller reads this so vertical arrow navigation jumps by the real column count.
    private(set) var lastTileTopCount = 0

    /// Shows `items` (with `selected` highlighted) anchored so its top-left sits at `topLeft`
    /// (AppKit screen coordinates, bottom-left origin). `layout` arranges them in a column, a single
    /// line, or a two-row tile.
    func show(_ items: [String], selected: Int, layout: PopupLayout, fontSize: CGFloat, topLeft: NSPoint) {
        let topCount = layout == .tile ? Self.tileTopCount(for: items, fontSize: fontSize, near: topLeft) : 0
        lastTileTopCount = topCount
        let host = NSHostingController(rootView: ListView(items: items, selected: selected,
                                                          layout: layout, fontSize: fontSize,
                                                          tileTopCount: topCount))
        let panel = self.panel ?? makePanel()
        panel.contentViewController = host
        panel.layoutIfNeeded()
        let size = host.view.fittingSize
        panel.setContentSize(size)
        panel.setFrameOrigin(clamp(NSPoint(x: topLeft.x, y: topLeft.y - size.height), size: size))
        panel.orderFront(nil) // NOT makeKey: must not take focus from the text field.
    }

    /// How many items fit on the first row of a tile, measured with the same font the chips use.
    /// Words are packed left to right until the next one would overflow the screen, so every word
    /// that fits stays on the first row; a word that alone exceeds the width still gets its own row.
    private static func tileTopCount(for items: [String], fontSize: CGFloat, near topLeft: NSPoint) -> Int {
        guard items.count > 1 else { return items.count }
        let probe = NSPoint(x: topLeft.x, y: topLeft.y + 10)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(probe) }) ?? NSScreen.main else {
            return PopupLayout.tileColumns(forCount: items.count)
        }
        let maxWidth = min(screen.visibleFrame.width - 80, 600)
        let maxContent = maxWidth - 4 // outer padding 2 + 2
        let font = NSFont.systemFont(ofSize: fontSize)
        var used: CGFloat = 0
        var topCount = 0
        for word in items {
            let textWidth = (word as NSString).size(withAttributes: [.font: font]).width
            let chip = ceil(textWidth) + 12 // horizontal padding 5 + 5, plus a little slack
            let withSpacing = chip + (topCount > 0 ? 4 : 0) // HStack spacing between chips
            if topCount > 0, used + withSpacing > maxContent { break }
            used += withSpacing
            topCount += 1
        }
        return max(1, topCount)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        self.panel = panel
        return panel
    }

    /// Keeps the panel fully on the screen that holds the anchor.
    private func clamp(_ origin: NSPoint, size: NSSize) -> NSPoint {
        let anchor = NSPoint(x: origin.x, y: origin.y + size.height)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main else {
            return origin
        }
        let v = screen.visibleFrame
        return NSPoint(x: min(max(origin.x, v.minX + 4), v.maxX - size.width - 4),
                       y: min(max(origin.y, v.minY + 4), v.maxY - size.height - 4))
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
                    ForEach(itemIndices, id: \.self) { chip($0) }
                }
            case .line:
                HStack(spacing: 4) {
                    ForEach(itemIndices, id: \.self) { chip($0) }
                }
            case .tile:
                // Two rows, filled left to right. The split is measured in show(), so every word
                // that fits stays on the first row. Both rows start at the leading edge.
                let topCount = tileTopCount > 0 ? tileTopCount : PopupLayout.tileColumns(forCount: items.count)
                let topRow = Array(items.indices.prefix(topCount))
                let bottomRow = Array(items.indices.dropFirst(topCount))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) { ForEach(topRow, id: \.self) { chip($0) } }
                    if !bottomRow.isEmpty {
                        HStack(spacing: 4) { ForEach(bottomRow, id: \.self) { chip($0) } }
                    }
                }
            }
        }
        .padding(2)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .fixedSize()
    }

    private var itemIndices: [Int] { Array(items.indices) }

    // Weight stays constant (only the background and color change on selection) so the layout does
    // not resize as the selection moves. The selected chip scales up slightly; words are never
    // truncated (a long completion wraps instead of ending in an ellipsis).
    private func chip(_ index: Int) -> some View {
        Text(items[index])
            .font(.system(size: fontSize, weight: .regular))
            .foregroundStyle(index == selected ? Color.accentColor : Color.primary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .frame(maxWidth: layout == .column ? .infinity : nil, alignment: .leading)
            .background(index == selected ? Color.accentColor.opacity(0.18) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 4))
            .scaleEffect(index == selected ? 1.10 : 1.0)
            .animation(.easeOut(duration: 0.12), value: index == selected)
    }
}
