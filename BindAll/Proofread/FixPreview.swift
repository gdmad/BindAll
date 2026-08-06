import AppKit
import SwiftUI

/// A tiny non-activating, click-through panel that previews the hovered fix right over the word it
/// would replace. It never takes focus and never blocks clicks; it only draws, so no app state is
/// touched and the undo history of the user's field stays clean.
@MainActor
final class FixPreview {
    private var panel: NSPanel?

    /// Shows `text` centered over `anchor` (the word's rect in AppKit screen coordinates,
    /// bottom-left origin).
    func show(text: String, anchor: CGRect) {
        guard !text.isEmpty else { hide(); return }
        let host = NSHostingController(rootView: PreviewLabel(text: text))
        let panel = self.panel ?? makePanel()
        panel.contentViewController = host
        panel.layoutIfNeeded()
        let size = host.view.fittingSize
        panel.setContentSize(size)
        panel.setFrameOrigin(clamp(NSPoint(x: anchor.midX - size.width / 2,
                                           y: anchor.midY - size.height / 2), size: size))
        panel.orderFront(nil) // NOT makeKey: the text field must keep focus.
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.ignoresMouseEvents = true // click-through: the popup below must keep its hovers
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        self.panel = panel
        return panel
    }

    /// Keeps the label fully on the screen that holds the anchor.
    private func clamp(_ origin: NSPoint, size: NSSize) -> NSPoint {
        let center = NSPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main else {
            return origin
        }
        let v = screen.visibleFrame
        return NSPoint(x: min(max(origin.x, v.minX + 4), v.maxX - size.width - 4),
                       y: min(max(origin.y, v.minY + 4), v.maxY - size.height - 4))
    }
}

private struct PreviewLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color(nsColor: .selectedMenuItemTextColor))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color(nsColor: .selectedContentBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 5))
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            .fixedSize()
    }
}
