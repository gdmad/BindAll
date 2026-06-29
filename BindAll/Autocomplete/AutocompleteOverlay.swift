import AppKit
import SwiftUI

/// A tiny, non-activating floating list of completion candidates near the caret. It never becomes the
/// key window, so it does not steal focus from the text field being typed into.
final class AutocompleteOverlay {
    private var panel: NSPanel?

    /// Shows `items` (with `selected` highlighted) anchored so its top-left sits at `topLeft`
    /// (AppKit screen coordinates, bottom-left origin). `horizontal` lays items in a line.
    func show(_ items: [String], selected: Int, horizontal: Bool, fontSize: CGFloat, topLeft: NSPoint) {
        let host = NSHostingController(rootView: ListView(items: items, selected: selected,
                                                          horizontal: horizontal, fontSize: fontSize))
        let panel = self.panel ?? makePanel()
        panel.contentViewController = host
        panel.layoutIfNeeded()
        let size = host.view.fittingSize
        panel.setContentSize(size)
        panel.setFrameOrigin(clamp(NSPoint(x: topLeft.x, y: topLeft.y - size.height), size: size))
        panel.orderFront(nil) // NOT makeKey: must not take focus from the text field.
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
    let horizontal: Bool
    let fontSize: CGFloat

    var body: some View {
        Group {
            if horizontal {
                HStack(spacing: 4) {
                    ForEach(itemIndices, id: \.self) { chip($0) }
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(itemIndices, id: \.self) { chip($0) }
                }
            }
        }
        .padding(4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
        .fixedSize()
    }

    private var itemIndices: [Int] { Array(items.indices) }

    // Weight stays constant (only the background and color change on selection) so the layout does
    // not resize as the selection moves.
    private func chip(_ index: Int) -> some View {
        Text(items[index])
            .font(.system(size: fontSize, weight: .regular))
            .foregroundStyle(index == selected ? Color.accentColor : Color.primary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(minWidth: horizontal ? nil : 90, alignment: .leading)
            .background(index == selected ? Color.accentColor.opacity(0.18) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5))
    }
}
