import AppKit
import SwiftUI

/// A transparent area that drags its window. The popup turns off "movable by background" so that
/// a drag across its text selects it; this restores dragging for the header alone.
struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}
