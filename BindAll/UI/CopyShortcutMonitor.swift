import AppKit

/// ⌘C in a translation window: copies what is selected when something is, and the whole
/// translation otherwise -- so the usual "select, ⌘C" still works, and a bare ⌘C needs no selecting.
///
/// The copy is sent straight to the responder chain rather than left to the menu bar: a menu-bar
/// agent has no Edit menu to turn ⌘C into `copy:` while only a panel is showing.
@MainActor
final class CopyShortcutMonitor {
    private var monitor: Any?

    func install(on window: NSWindow, copyAll: @escaping @MainActor () -> Void) {
        remove()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window] event in
            guard let window, event.window === window, Self.isCopyShortcut(event) else { return event }
            let pasteboard = NSPasteboard.general
            let before = pasteboard.changeCount
            if let responder = Self.copyResponder(in: window) {
                _ = responder.tryToPerform(#selector(NSText.copy(_:)), with: window)
            }
            if pasteboard.changeCount == before { copyAll() }
            return nil
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private static func isCopyShortcut(_ event: NSEvent) -> Bool {
        // Matched by key code, not character: with a Russian layout the key reads "с".
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        return modifiers == .command && event.keyCode == 8
    }

    /// The responder that would copy, if it has a selection to copy -- asked the way the Edit menu
    /// would ask it. Walks the window's own chain: the app need not be active for its panel to be key.
    private static func copyResponder(in window: NSWindow) -> NSResponder? {
        let action = #selector(NSText.copy(_:))
        var responder = window.firstResponder
        while let current = responder, !current.responds(to: action) {
            responder = current.nextResponder
        }
        guard let target = responder else { return nil }
        let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
        if let validator = target as? NSMenuItemValidation { return validator.validateMenuItem(item) ? target : nil }
        if let validator = target as? NSUserInterfaceValidations {
            return validator.validateUserInterfaceItem(item) ? target : nil
        }
        return target
    }
}
