import AppKit
import SwiftUI

/// A tiny, non-activating floating chip that shows a completion near the caret. It never becomes the
/// key window, so it does not steal focus from the text field being typed into.
final class AutocompleteOverlay {
    private var panel: NSPanel?

    /// Shows `text` anchored just below `caretRect` (screen coordinates, top-left origin, as returned
    /// by the Accessibility `kAXBoundsForRange` attribute).
    func show(_ text: String, at caretRect: CGRect) {
        let host = NSHostingController(rootView: ChipView(text: text))
        let panel = self.panel ?? makePanel()
        panel.contentViewController = host
        panel.layoutIfNeeded()
        let size = host.view.fittingSize
        panel.setContentSize(size)
        panel.setFrameOrigin(origin(for: caretRect, size: size))
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

    /// Converts the Quartz (top-left origin) caret rect into an AppKit (bottom-left origin) point just
    /// below the caret.
    private func origin(for caretRect: CGRect, size: NSSize) -> NSPoint {
        let primaryHeight = (NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main)?
            .frame.height ?? caretRect.maxY
        let y = primaryHeight - caretRect.maxY - size.height - 2
        return NSPoint(x: caretRect.minX, y: y)
    }
}

private struct ChipView: View {
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            Text(text).font(.system(size: 12, weight: .medium))
            Text("\u{21E5}").font(.system(size: 10)).foregroundStyle(.secondary) // Tab glyph
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
        .fixedSize()
    }
}
