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
    /// Some native apps (Reasonix among them) report `kAXSelectedText` as settable and claim the
    /// write succeeded without changing anything. Path A's verify() catches that; instead of giving
    /// up with `.stale`, the fix now falls through to the select-and-paste path, with a guard so a
    /// write that did land asynchronously is never pasted a second time.
    static func apply(_ issue: TextIssue, replacement: String, element: AXUIElement, pid: pid_t,
                      restoreClipboard: Bool) async -> Result {
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
        // has at that range and shift until its own text agrees -- or refuse.
        guard let range = ProofreadAX.alignedRange(ourRange, expecting: issue.original, in: element,
                                                   contextBefore: issue.contextBefore,
                                                   contextAfter: issue.contextAfter) else {
            log.debug("alignedRange found nothing matching near \(ourRange)")
            return .stale
        }
        log.debug("relocated to \(ourRange), app-aligned to \(range)")

        // Path A: write straight into the selection. The caret stays put and the pasteboard is
        // untouched, so this is the path to prefer wherever the app allows it. Chromium is excluded:
        // it reports the attribute as settable, then applies the write asynchronously, so verify()
        // reads the pre-write value and every fix would look stale.
        if !ProofreadAX.isChromium(pid: pid),
           ProofreadAX.canSetSelectedText(element), ProofreadAX.select(range, in: element) {
            if AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString,
                                            replacement as CFString) == .success {
                if verify(element: element, at: range.location, equals: replacement) {
                    log.debug("path A write verified")
                    return .applied(replacedRange: ourRange)
                }
                // The write claimed success but the text did not change. The write may still have
                // landed asynchronously (the AX value lags the editor), so check for it; otherwise
                // fall through to the paste path instead of returning stale.
                if writeLanded(replacement: replacement, near: range.location, in: element) {
                    log.debug("path A claimed success and the write landed asynchronously")
                    return .applied(replacedRange: ourRange)
                }
                log.debug("path A claimed success but did not land; falling through to the paste path")
            }
        }

        // Path B: Electron and Chromium fields usually accept a selection but refuse a text write.
        // Select the range and paste over it, which is the path the rest of the app already uses.
        guard ProofreadAX.select(range, in: element) else {
            log.debug("select failed: the app does not accept selections")
            return .failed("This app does not support in-place fixes.")
        }
        // If Path A's write landed after all, the text at the range is the replacement now; pasting
        // would apply the fix twice, so treat it as applied.
        if let now = ProofreadAX.currentText(of: element) {
            let ns = now as NSString
            if NSMaxRange(range) <= ns.length, ns.substring(with: range) == replacement {
                log.debug("the fix is already in the field; skipping the paste")
                return .applied(replacedRange: ourRange)
            }
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
        return .applied(replacedRange: ourRange)
    }

    /// Whether a write that claimed success actually replaced the word near `location`: re-reads the
    /// field and looks for the replacement within a small window around the old position.
    private static func writeLanded(replacement: String, near location: Int, in element: AXUIElement) -> Bool {
        guard let text = ProofreadAX.currentText(of: element) else { return false }
        let ns = text as NSString
        let window = 32
        let start = max(0, location - window)
        let end = min(ns.length, location + (replacement as NSString).length + window)
        guard start < end else { return false }
        return ns.range(of: replacement, options: [.literal],
                        range: NSRange(location: start, length: end - start)).location != NSNotFound
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
