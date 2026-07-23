import AppKit
import ApplicationServices

/// Applies a single fix to the focused field.
@MainActor
enum IssueApplier {
    enum Result {
        /// The fix landed. `replacedRange` is where the ORIGINAL text sat when it was replaced
        /// (after relocation), so the caller can shift the remaining issue ranges from it.
        case applied(replacedRange: NSRange)
        /// The text moved or changed under us; nothing was (knowingly) written twice. Re-check
        /// before retrying.
        case stale
        case failed(String)
    }

    /// Replaces `issue`'s range with `replacement`.
    ///
    /// The field is always re-read first: the user may have kept typing while the panel was open, and
    /// writing to a stale range would corrupt unrelated text.
    static func apply(_ issue: TextIssue, replacement: String, element: AXUIElement, pid: pid_t,
                      restoreClipboard: Bool) -> Result {
        guard let text = ProofreadAX.currentText(of: element) else { return .failed("Cannot read the field.") }
        guard let range = IssueMerger.relocate(issue, in: text) else { return .stale }

        // Path A: write straight into the selection. The caret stays put and the pasteboard is
        // untouched, so this is the path to prefer wherever the app allows it. Chromium is excluded:
        // it reports the attribute as settable, then applies the write asynchronously, so verify()
        // reads the pre-write value and every fix would look stale.
        if !ProofreadAX.isChromium(pid: pid),
           ProofreadAX.canSetSelectedText(element), ProofreadAX.select(range, in: element) {
            if AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString,
                                            replacement as CFString) == .success {
                // The write claimed success. Never fall through to the paste path from here: if the
                // app actually wrote the text, pasting would apply the fix twice.
                return verify(element: element, at: range.location, equals: replacement)
                    ? .applied(replacedRange: range)
                    : .stale
            }
        }

        // Path B: Electron and Chromium fields usually accept a selection but refuse a text write.
        // Select the range and paste over it, which is the path the rest of the app already uses.
        guard ProofreadAX.select(range, in: element) else {
            return .failed("This app does not support in-place fixes.")
        }
        // select() returning success does not mean the selection took (Chromium can no-op): read it
        // back before pasting, or Cmd+V would land at the caret instead of over the issue. The
        // selected *text* is the strong signal; the range is only consulted when the text is
        // unreadable, because Chromium's range read-back can lag behind the selection it just made.
        if let selectedText = ProofreadAX.selectedText(of: element) {
            guard selectedText == issue.original else { return .stale }
        } else if let selected = ProofreadAX.selectedRange(of: element) {
            guard selected == range else { return .stale }
        }
        // The paste itself is fire-and-forget (it lands ~0.05-0.3 s later); FocusTarget re-activates
        // the app first and waits longer when it was not frontmost.
        TextInjector.replaceSelection(with: replacement, restorePrevious: restoreClipboard,
                                      target: TextInjector.FocusTarget(
                                          app: NSRunningApplication(processIdentifier: pid)))
        return .applied(replacedRange: range)
    }

    /// Confirms Path A actually wrote the text: some elements report success and change nothing.
    private static func verify(element: AXUIElement, at location: Int, equals replacement: String) -> Bool {
        guard let text = ProofreadAX.currentText(of: element) else { return false }
        let ns = text as NSString
        let range = NSRange(location: location, length: (replacement as NSString).length)
        guard NSMaxRange(range) <= ns.length else { return false }
        return ns.substring(with: range) == replacement
    }
}
