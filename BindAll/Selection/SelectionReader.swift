import AppKit

/// Reads the currently selected text.
///
/// Because the trigger hotkey is Cmd+C (the real copy shortcut), the selection is already on the
/// pasteboard by the time a burst fires. We read it directly, with a short poll to make sure the
/// last Cmd+C of the burst has landed. The Accessibility focused-element value is used as a fallback.
enum SelectionReader {
    /// Returns the selected text, or nil if nothing usable was found.
    static func currentSelection(previousChangeCount: Int) -> String? {
        let pb = NSPasteboard.general
        // Give the last synthetic/real copy a brief moment to update the pasteboard.
        let deadline = Date().addingTimeInterval(0.25)
        while pb.changeCount == previousChangeCount && Date() < deadline {
            usleep(15_000)
        }
        if let text = pb.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        return axSelectedText()
    }

    static var pasteboardChangeCount: Int { NSPasteboard.general.changeCount }

    /// Captures the selection for a trigger that does NOT copy by itself (per-action-key shortcuts):
    /// synthesizes Cmd+C, waits for the pasteboard to actually change, then reads it. Returns nil if
    /// the copy never landed (empty selection / app without copy), so a stale clipboard is never used.
    static func copyCurrentSelection() -> String? {
        let pb = NSPasteboard.general
        let before = pb.changeCount
        TextInjector.copySelection()

        // Poll finely so we return as soon as the copy lands instead of waiting a fixed delay.
        let deadline = Date().addingTimeInterval(0.22)
        while pb.changeCount == before && Date() < deadline {
            usleep(6_000)
        }

        guard pb.changeCount != before else {
            // The synthetic copy did not update the pasteboard — do not fall back to stale contents.
            return axSelectedText()
        }
        if let text = pb.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        return axSelectedText()
    }

    /// Fallback: read kAXSelectedTextAttribute from the focused UI element.
    private static func axSelectedText() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return nil }
        // Force-cast through CFType to AXUIElement.
        let axElement = element as! AXUIElement
        var selected: AnyObject?
        guard AXUIElementCopyAttributeValue(axElement, kAXSelectedTextAttribute as CFString, &selected) == .success,
              let text = selected as? String, !text.isEmpty else { return nil }
        return text
    }
}
