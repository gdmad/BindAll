import Foundation

/// Pure range algebra over `TextIssue` lists: combining provider results, and keeping ranges valid
/// after the user applies a fix.
enum IssueMerger {
    /// Normalizes a provider's results into one ordered, non-overlapping list.
    ///
    /// LanguageTool routinely reports several matches over the same or overlapping text (a typo rule
    /// and a grammar rule can both fire on one word). Stepping through those one by one would ask the
    /// user about the same word twice, and the second range would be stale after the first fix. So:
    ///   - identical ranges collapse into one issue keeping both sets of replacements;
    ///   - otherwise, scanning left to right, an issue overlapping an accepted one is dropped.
    /// Longer matches win, since they carry the more complete rewrite.
    static func merge(_ issues: [TextIssue]) -> [TextIssue] {
        let sorted = issues.filter { !$0.original.isEmpty }.sorted { a, b in
            if a.range.location != b.range.location { return a.range.location < b.range.location }
            return a.range.length > b.range.length
        }

        var out: [TextIssue] = []
        for issue in sorted {
            guard issue.range.length > 0 else { continue }
            guard let last = out.last else { out.append(issue); continue }

            if NSEqualRanges(last.range, issue.range) {
                var merged = last
                merged.replacements = dedup(last.replacements + issue.replacements)
                out[out.count - 1] = merged
                continue
            }
            // `sorted` guarantees issue.range.location >= last.range.location, so an overlap can only
            // mean this issue starts before the accepted one ends.
            if issue.range.location < NSMaxRange(last.range) { continue }
            out.append(issue)
        }
        return out
    }

    private static func dedup(_ words: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for word in words where seen.insert(word.lowercased()).inserted {
            out.append(word)
        }
        return out
    }

    /// Trims each issue's replacement list to `limit` (clamped to 1...10), keeping the best-first
    /// order. Applied once when issues are stored, so the popup, keyboard navigation and accept all
    /// see the same list.
    static func capReplacements(_ issues: [TextIssue], limit: Int) -> [TextIssue] {
        let cap = max(1, min(10, limit))
        return issues.map { issue in
            var capped = issue
            capped.replacements = Array(issue.replacements.prefix(cap))
            return capped
        }
    }

    /// Updates `issues` after `replacedRange` was replaced by text of `replacementUTF16Length`.
    /// Issues before the edit are untouched, issues after it slide, and issues that overlap the edit
    /// (including the one that was just applied) are dropped: their text no longer exists.
    static func shift(_ issues: [TextIssue], replacedRange: NSRange,
                      replacementUTF16Length: Int) -> [TextIssue] {
        let delta = replacementUTF16Length - replacedRange.length
        return issues.compactMap { issue in
            if NSMaxRange(issue.range) <= replacedRange.location { return issue }
            if issue.range.location >= NSMaxRange(replacedRange) {
                return issue.withRange(NSRange(location: issue.range.location + delta,
                                               length: issue.range.length))
            }
            return nil // overlaps the edit
        }
    }

    /// Finds where `issue.original` sits in `text` now.
    ///
    /// The user can keep typing while the panel is open, so by the time they click a fix the text may
    /// have moved. Returns the range only when it is unambiguous: either the text is still exactly
    /// where it was, or there is exactly one occurrence within `window` UTF-16 units of the old spot.
    /// Anything else returns nil, and the caller must re-check rather than guess.
    static func relocate(_ issue: TextIssue, in text: String, window: Int = 64) -> NSRange? {
        let ns = text as NSString
        let original = issue.original as NSString
        guard original.length > 0 else { return nil }

        if NSMaxRange(issue.range) <= ns.length,
           ns.substring(with: issue.range) == issue.original {
            return issue.range
        }

        let start = max(0, issue.range.location - window)
        let end = min(ns.length, NSMaxRange(issue.range) + window)
        guard start < end else { return nil }
        let search = NSRange(location: start, length: end - start)

        var found: NSRange?
        var cursor = search
        while cursor.length > 0 {
            let hit = ns.range(of: issue.original, options: [.literal], range: cursor)
            guard hit.location != NSNotFound else { break }
            if found != nil { return nil } // ambiguous
            found = hit
            let next = NSMaxRange(hit)
            cursor = NSRange(location: next, length: max(0, NSMaxRange(search) - next))
        }
        return found
    }

    /// The first issue that overlaps `selection`, for the popup shown when the user selects a word.
    static func firstIssue(in issues: [TextIssue], overlapping selection: NSRange) -> TextIssue? {
        issues.first { NSIntersectionRange($0.range, selection).length > 0
            || (selection.length == 0 && NSLocationInRange(selection.location, $0.range)) }
    }
}
