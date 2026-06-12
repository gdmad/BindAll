import AppKit
import Carbon.HIToolbox

/// Replaces the current selection by putting text on the pasteboard and synthesizing Cmd+V.
enum TextInjector {
    /// Copies `text` to the pasteboard and pastes it into the frontmost app.
    /// - Parameter restorePrevious: if true, the prior pasteboard string is restored shortly after.
    static func replaceSelection(with text: String, restorePrevious: Bool) {
        let pb = NSPasteboard.general
        let previous = restorePrevious ? pb.string(forType: .string) : nil

        pb.clearContents()
        pb.setString(text, forType: .string)

        // Small delay so the pasteboard write is visible to the target app.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            paste()
            if restorePrevious, let previous {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    pb.clearContents()
                    pb.setString(previous, forType: .string)
                }
            }
        }
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
