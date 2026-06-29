import AppKit
import Carbon.HIToolbox

/// Replaces the current selection by putting text on the pasteboard and synthesizing Cmd+V.
enum TextInjector {
    /// The app that was frontmost when an action started, so the result can be pasted back into it
    /// even if the user moves focus while the engine is working.
    struct FocusTarget {
        let app: NSRunningApplication?

        /// Snapshot of the frontmost app. Call on the main thread.
        static func capture() -> FocusTarget {
            FocusTarget(app: NSWorkspace.shared.frontmostApplication)
        }
    }

    /// Replaces the selection with `text` by pasting it (Cmd+V), which works reliably across native
    /// and Electron/Chromium apps. If focus moved to another app while the engine worked, the original
    /// app is re-activated first so the result lands where the action started.
    static func replaceSelection(with text: String, restorePrevious: Bool, target: FocusTarget? = nil) {
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let stillFrontmost = target?.app == nil || target?.app?.processIdentifier == frontPid
        if !stillFrontmost { target?.app?.activate() }
        pasteText(text, restorePrevious: restorePrevious, delay: stillFrontmost ? 0.05 : 0.3)
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
