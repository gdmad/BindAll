import AppKit
import ApplicationServices

/// Applies a single fix to the focused field.
@MainActor
enum IssueApplier {
    enum Result {
        /// The fix landed; `range` is where the replacement now sits.
        case applied(range: NSRange)
        /// The text moved or changed under us; nothing was written. Re-check before retrying.
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
        // untouched, so this is the path to prefer wherever the app allows it.
        if ProofreadAX.canSetSelectedText(element), ProofreadAX.select(range, in: element) {
            if AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString,
                                            replacement as CFString) == .success,
               verify(element: element, at: range.location, equals: replacement) {
                return .applied(range: NSRange(location: range.location,
                                               length: (replacement as NSString).length))
            }
        }

        // Path B: Electron and Chromium fields usually accept a selection but refuse a text write.
        // Select the range and paste over it, which is the path the rest of the app already uses.
        guard ProofreadAX.select(range, in: element) else {
            return .failed("This app does not support in-place fixes.")
        }
        NSRunningApplication(processIdentifier: pid)?.activate()
        TextInjector.replaceSelection(with: replacement, restorePrevious: restoreClipboard)
        return .applied(range: NSRange(location: range.location, length: (replacement as NSString).length))
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
