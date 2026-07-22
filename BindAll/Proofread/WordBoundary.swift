import Foundation

/// Pure word-boundary lookup used by the click-to-proofread trigger. Foundation-only so it
/// compiles in the plain-swiftc test harness.
enum WordBoundary {
    /// UTF-16 range of the word at `caret` in `text`; nil when the caret is not on a word or
    /// immediately after one. All offsets are UTF-16, matching TextIssue.range and AX.
    static func wordRange(at caret: Int, in text: String) -> NSRange? {
        let ns = text as NSString
        guard ns.length > 0 else { return nil }
        let caret = max(0, min(caret, ns.length))

        // Scan only a small window around the caret; snap it outward to composed-character
        // boundaries so surrogate pairs (emoji) are never split.
        var start = max(0, caret - 64)
        var end = min(ns.length, caret + 64)
        if start > 0 { start = ns.rangeOfComposedCharacterSequence(at: start).location }
        if end < ns.length { end = NSMaxRange(ns.rangeOfComposedCharacterSequence(at: end)) }

        var containing: NSRange?
        var endingAtCaret: NSRange?
        ns.enumerateSubstrings(in: NSRange(location: start, length: end - start),
                               options: [.byWords, .substringNotRequired]) { _, range, _, stop in
            if NSLocationInRange(caret, range) {
                containing = range
                stop.pointee = true
            } else if NSMaxRange(range) == caret {
                // Click at a word's right edge: NSLocationInRange excludes the end position.
                endingAtCaret = range
            } else if range.location > caret {
                stop.pointee = true
            }
        }
        return containing ?? endingAtCaret
    }
}
