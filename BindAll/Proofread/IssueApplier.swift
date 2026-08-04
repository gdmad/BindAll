import AppKit
import ApplicationServices
import os

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

    private static let log = Logger(subsystem: "com.evgeny.bindall", category: "issue-applier")

    /// Replaces `issue`'s range with `replacement`.
    ///
    /// The field is always re-read first: the user may have kept typing while the panel was open, and
    /// writing to a stale range would corrupt unrelated text.
    ///
    /// Chromium's accessibility tree updates lazily, so a paste-path attempt can legitimately observe
    /// pre-edit state and report `.stale` without having written anything. Those apps get one retry
    /// with everything re-read; native apps write synchronously and are never retried, because a
    /// blind retry after a write that may have landed could apply the fix twice.
    static func apply(_ issue: TextIssue, replacement: String, element: AXUIElement, pid: pid_t,
                      restoreClipboard: Bool) async -> Result {
        for attempt in 0..<2 {
            let result = await applyOnce(issue, replacement: replacement, element: element, pid: pid,
                                         restoreClipboard: restoreClipboard)
            if case .stale = result, attempt == 0, ProofreadAX.isChromium(pid: pid) {
                log.debug("stale on the first attempt in a Chromium app; re-reading the field and retrying once")
                continue
            }
            return result
        }
        return .stale
    }

    private static func applyOnce(_ issue: TextIssue, replacement: String, element: AXUIElement,
                                  pid: pid_t, restoreClipboard: Bool) async -> Result {
        guard let text = ProofreadAX.currentText(of: element) else {
            log.error("cannot read the field")
            return .failed("Cannot read the field.")
        }
        guard let ourRange = IssueMerger.relocate(issue, in: text) else {
            log.debug("relocate failed: the issue's text is no longer at or near its range")
            return .stale
        }
        // Our offsets come from the field's value; the app's selection may be indexed differently
        // (Chromium's are), which is how a fix ends up on the neighbouring word. Ask the app what it
        // has at that range and shift until its own text agrees -- or refuse. After an applied fix
        // the Chromium offsets can drift by more than a word, so the probe window is wider there.
        let window = ProofreadAX.isChromium(pid: pid) ? 64 : 16
        guard let range = ProofreadAX.alignedRange(ourRange, expecting: issue.original, in: element,
                                                   contextBefore: issue.contextBefore,
                                                   contextAfter: issue.contextAfter,
                                                   window: window) else {
            log.debug("alignedRange found nothing matching within window \(window)")
            return .stale
        }
        log.debug("relocated to \(ourRange), app-aligned to \(range) (window \(window))")

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
                let ok = verify(element: element, at: range.location, equals: replacement)
                log.debug("path A in-place write verified: \(ok)")
                return ok ? .applied(replacedRange: range) : .stale
            }
        }

        // Path B: Electron and Chromium fields usually accept a selection but refuse a text write.
        // Select the range and paste over it, which is the path the rest of the app already uses.
        guard ProofreadAX.select(range, in: element) else {
            log.debug("select failed: the app does not accept selections")
            return .failed("This app does not support in-place fixes.")
        }
        // select() returning success does not mean the selection took: Chromium updates its
        // accessibility cache straight away while the editor's real selection lands a moment later,
        // so pasting immediately can overwrite whatever was selected *before* -- the previous issue.
        // Wait for the selected text to actually read back as this issue's text before pasting.
        guard await selectionSettled(on: element, equals: issue.original, range: range) else {
            log.debug("selection never settled on the issue's text")
            return .stale
        }
        // The paste itself is fire-and-forget (it lands ~0.05-0.3 s later); FocusTarget re-activates
        // the app first and waits longer when it was not frontmost.
        log.debug("selection settled; pasting the fix")
        TextInjector.replaceSelection(with: replacement, restorePrevious: restoreClipboard,
                                      target: TextInjector.FocusTarget(
                                          app: NSRunningApplication(processIdentifier: pid)))
        return .applied(replacedRange: range)
    }

    /// Waits (briefly) until the field reports `original` as its selected text, so the paste can
    /// only land on the issue we mean. Two consecutive matching reads are required: a single one can
    /// still be Chromium's cache echoing the range we just wrote back at us.
    private static func selectionSettled(on element: AXUIElement, equals original: String,
                                         range: NSRange) async -> Bool {
        var confirmations = 0
        for attempt in 0..<8 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 40_000_000) }
            guard let selectedRange = ProofreadAX.selectedRange(of: element) else {
                // No readable selection: the selected text is the only thing left to check.
                if let selected = ProofreadAX.selectedText(of: element) {
                    confirmations = selected == original ? confirmations + 1 : 0
                    if confirmations >= 2 { return true }
                    continue
                }
                return true // the app exposes neither; nothing left to check against
            }
            // What the app says is selected, by its own reckoning -- not our arithmetic. Chromium
            // echoes the range we wrote straight back, so the range alone proves nothing.
            let selectedText = ProofreadAX.string(for: selectedRange, in: element)
                ?? ProofreadAX.selectedText(of: element)
            if let selectedText {
                confirmations = selectedText == original ? confirmations + 1 : 0
            } else {
                confirmations = selectedRange == range ? confirmations + 1 : 0
            }
            if confirmations >= 2 { return true }
        }
        return false
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
