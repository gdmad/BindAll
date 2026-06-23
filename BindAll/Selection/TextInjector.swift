import AppKit
import Carbon.HIToolbox

/// Replaces the current selection by putting text on the pasteboard and synthesizing Cmd+V.
enum TextInjector {
    /// The app + focused element captured when an action starts, so the result lands in the right
    /// place even if the user moves focus while the engine is working.
    struct FocusTarget {
        let app: NSRunningApplication?
        let element: AXUIElement?

        /// Snapshot of the frontmost app and its focused UI element. Call on the main thread.
        static func capture() -> FocusTarget {
            let app = NSWorkspace.shared.frontmostApplication
            var focused: AnyObject?
            let system = AXUIElementCreateSystemWide()
            var element: AXUIElement?
            if AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
               let f = focused {
                element = (f as! AXUIElement)
            }
            return FocusTarget(app: app, element: element)
        }
    }

    /// Replaces the selection with `text`.
    ///
    /// Prefers a direct Accessibility write into the captured `target` element: it hits the exact
    /// field even if focus moved and does not touch the clipboard. Falls back to re-activating the
    /// captured app and pasting via the clipboard when AX writing is not supported.
    static func replaceSelection(with text: String, restorePrevious: Bool, target: FocusTarget? = nil) {
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let stillFrontmost = target?.app == nil || target?.app?.processIdentifier == frontPid

        if stillFrontmost {
            // Focus never left the target: write straight into the focused element (no clipboard),
            // or paste if the element does not allow direct AX writing.
            if let element = target?.element, axReplaceSelectedText(element, with: text) { return }
            pasteText(text, restorePrevious: restorePrevious, delay: 0.05)
        } else {
            // The user moved to another app while we worked: bring the original one back first, then
            // paste once it has come forward.
            target?.app?.activate()
            pasteText(text, restorePrevious: restorePrevious, delay: 0.3)
        }
    }

    /// Puts `text` on the pasteboard and pastes it after `delay`, optionally restoring the clipboard.
    private static func pasteText(_ text: String, restorePrevious: Bool, delay: TimeInterval) {
        let pb = NSPasteboard.general
        let previous = restorePrevious ? pb.string(forType: .string) : nil
        pb.clearContents()
        pb.setString(text, forType: .string)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            paste()
            if restorePrevious, let previous {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    pb.clearContents()
                    pb.setString(previous, forType: .string)
                }
            }
        }
    }

    /// Replaces the selected text of an Accessibility element directly. Returns false when the
    /// element does not allow it (e.g. web views / Electron apps), so the caller can fall back.
    private static func axReplaceSelectedText(_ element: AXUIElement, with text: String) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }

    /// Just place text on the pasteboard (used by the popup "Copy" button).
    static func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Synthesizes a Cmd+V keystroke.
    static func paste() {
        postCommandKey(CGKeyCode(kVK_ANSI_V))
    }

    /// Synthesizes a Cmd+C keystroke. Used to capture the selection for shortcuts that are not
    /// themselves the copy shortcut (per-action-key shortcuts).
    static func copySelection() {
        postCommandKey(CGKeyCode(kVK_ANSI_C))
    }

    private static func postCommandKey(_ key: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }
}
