import AppKit
import SwiftUI

/// Shows a small floating panel near the mouse with result text, an optional original-text section,
/// a Copy button and a Close button. The panel can become key so Esc and text selection work.
/// It stays until Esc or Close: a click elsewhere used to close it, which lost the translation the
/// moment the user switched apps to paste it.
@MainActor
final class PopupController {
    private var panel: NSPanel?

    func show(title: String, text: String, original: String? = nil, sourceLanguage: String? = nil,
              targetLanguage: String? = nil, at screenPoint: NSPoint? = nil) {
        close()

        let model = PopupModel(title: title, text: text, original: original,
                               sourceLanguage: sourceLanguage, targetLanguage: targetLanguage,
                               onClose: { [weak self] in self?.close() })

        let hosting = NSHostingController(rootView: PopupView(model: model))
        let panel = KeyablePanel(contentViewController: hosting)
        panel.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { panel.standardWindowButton($0)?.isHidden = true }
        // Only the header moves the panel (`WindowDragHandle`): dragging across the body selects text.
        panel.isMovableByWindowBackground = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.setContentSize(NSSize(width: 380, height: 260))
        self.panel = panel

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        positionPanel(panel, near: screenPoint ?? NSEvent.mouseLocation)
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }

    private func positionPanel(_ panel: NSPanel, near point: NSPoint) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main else {
            panel.setFrameOrigin(point)
            return
        }
        let size = panel.frame.size
        var origin = NSPoint(x: point.x + 12, y: point.y - size.height - 12)
        let visible = screen.visibleFrame
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        panel.setFrameOrigin(origin)
    }
}
