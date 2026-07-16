import Foundation

/// Pure range algebra over `TextIssue` lists: combining provider results, and keeping ranges valid
/// after the user applies a fix.
enum IssueMerger {
    /// Merges the providers' results into one ordered, non-overlapping list.
    ///
    /// Two providers routinely flag the same word, and rendering both would show the user a
    /// duplicate. The rules:
    ///   - issues whose `original` is in `ignored` (case-insensitive) are dropped;
    ///   - identical ranges are combined into the higher-priority issue, keeping both sets of
    ///     replacements (higher-priority ones first);
    ///   - otherwise, scanning left to right, an issue that overlaps an already-accepted one loses.
    static func merge(_ lists: [[TextIssue]], ignoring ignored: Set<String> = []) -> [TextIssue] {
        let all = lists.flatMap { $0 }.filter { issue in
            !issue.original.isEmpty && !ignored.contains(issue.original.lowercased())
        }

        // Longer and higher-priority issues come first at a given location, so that the left-to-right
        // scan below keeps the more informative one when ranges collide.
        let sorted = all.sorted { a, b in
            if a.range.location != b.range.location { return a.range.location < b.range.location }
            if a.range.length != b.range.length { return a.range.length > b.range.length }
            return a.priority > b.priority
        }

        var out: [TextIssue] = []
        for issue in sorted {
            guard issue.range.length > 0 else { continue }
            guard let last = out.last else { out.append(issue); continue }

            if NSEqualRanges(last.range, issue.range) {
                out[out.count - 1] = combine(last, issue)
                continue
            }
            // `sorted` guarantees issue.range.location >= last.range.location, so an overlap can only
            // mean this issue starts before the accepted one ends.
            if issue.range.location < NSMaxRange(last.range) { continue }
            out.append(issue)
        }
        return out
    }

    /// Combines two issues covering the same range: the higher-priority one wins, but keeps the
    /// other's replacements as extra options.
    private static func combine(_ a: TextIssue, _ b: TextIssue) -> TextIssue {
        let (winner, loser) = a.priority >= b.priority ? (a, b) : (b, a)
        var merged = winner
        merged.replacements = dedup(winner.replacements + loser.replacements)
        return merged
    }

    private static func dedup(_ words: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for word in words where seen.insert(word.lowercased()).inserted {
            out.append(word)
        }
        return out
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

    /// Drops issues touching the caret. The word being typed right now is usually incomplete, and
    /// flagging it as misspelled mid-keystroke is noise rather than help.
    static func excludingCaretWord(_ issues: [TextIssue], caret: Int) -> [TextIssue] {
        issues.filter { caret < $0.range.location || caret > NSMaxRange($0.range) }
    }
}
