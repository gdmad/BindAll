import AppKit

/// A panel that can become key (so the user can type), even from an accessory (menu-bar) app.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
