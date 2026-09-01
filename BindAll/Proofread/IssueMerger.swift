import Foundation

/// Pure range algebra over `TextIssue` lists: combining provider results, and keeping ranges valid
/// after the user applies a fix.
enum IssueMerger {
    /// Normalizes a provider's results into one ordered, non-overlapping list.
    ///
    /// LanguageTool routinely reports several matches over the same or overlapping text (a typo rule
    /// and a grammar rule can both fire on one word). Stepping through those one by one would ask the
    /// user about the same word twice, and the second range would be stale after the first fix. So,
    /// scanning left to right and tracking the reach of the current cluster of overlapping matches:
    ///   - identical ranges collapse into one issue keeping both sets of replacements;
    ///   - otherwise the longer match wins and replaces the shorter one already kept for this cluster.
    /// The cluster's reach is the max end of every match seen in it, not just the current winner's --
    /// a match that starts late but is itself short can still be swallowed by an earlier, longer one.
    static func merge(_ issues: [TextIssue]) -> [TextIssue] {
        let sorted = issues.filter { !$0.original.isEmpty }.sorted { a, b in
            if a.range.location != b.range.location { return a.range.location < b.range.location }
            return a.range.length > b.range.length
        }

        var out: [TextIssue] = []
        var clusterEnd = 0
        for issue in sorted {
            guard issue.range.length > 0 else { continue }
            guard !out.isEmpty, issue.range.location < clusterEnd else {
                out.append(issue)
                clusterEnd = NSMaxRange(issue.range)
                continue
            }

            clusterEnd = max(clusterEnd, NSMaxRange(issue.range))
            let winner = out[out.count - 1]
            if NSEqualRanges(winner.range, issue.range) {
                var merged = winner
                merged.replacements = dedup(winner.replacements + issue.replacements)
                out[out.count - 1] = merged
            } else if issue.range.length > winner.range.length {
                out[out.count - 1] = issue
            }
            // else: shorter (or equal-length, different-range) match loses the cluster and is dropped.
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
    /// have moved. When the issue carries a context snapshot, every candidate occurrence within
    /// `window` UTF-16 units is scored by how much of its surroundings still match that snapshot --
    /// this is what tells two identical words apart. Without context (legacy issues), the old rule
    /// applies: the exact old position, else a single unambiguous occurrence. Anything ambiguous
    /// returns nil, and the caller must re-check rather than guess.
    static func relocate(_ issue: TextIssue, in text: String, window: Int = 64) -> NSRange? {
        let ns = text as NSString
        let original = issue.original as NSString
        guard original.length > 0 else { return nil }

        let oldRangeValid = NSMaxRange(issue.range) <= ns.length
            && ns.substring(with: issue.range) == issue.original
        let hasContext = !issue.contextBefore.isEmpty || !issue.contextAfter.isEmpty

        if oldRangeValid && !hasContext { return issue.range }

        // Collect every occurrence in the window (plus the old range, which may sit outside it).
        let start = max(0, issue.range.location - window)
        let end = min(ns.length, NSMaxRange(issue.range) + window)
        var candidates: [NSRange] = []
        if start < end {
            var cursor = NSRange(location: start, length: end - start)
            while cursor.length > 0 {
                let hit = ns.range(of: issue.original, options: [.literal], range: cursor)
                guard hit.location != NSNotFound else { break }
                candidates.append(hit)
                let next = NSMaxRange(hit)
                cursor = NSRange(location: next, length: max(0, end - next))
            }
        }
        if oldRangeValid && !candidates.contains(issue.range) { candidates.append(issue.range) }

        guard !candidates.isEmpty else { return nil }
        guard hasContext else {
            return candidates.count == 1 ? candidates[0] : nil // legacy: unique hit or bail
        }

        let scored = candidates.map { (range: $0, score: contextScore($0, in: ns, issue: issue)) }
        let best = scored.max { $0.score < $1.score }!
        // A word's neighbours are usually spaces, and a space matches almost anywhere -- so demand a
        // few real characters of agreement (or all of it, when the snapshot itself is that short).
        let available = (issue.contextBefore as NSString).length + (issue.contextAfter as NSString).length
        guard best.score >= min(4, available), best.score > 0 else { return nil }
        let winners = scored.filter { $0.score == best.score }
        if winners.count == 1 { return winners[0].range }
        // Tie: trust the unmoved position if it is among the winners, otherwise it is ambiguous.
        if oldRangeValid, winners.contains(where: { $0.range == issue.range }) { return issue.range }
        return nil
    }

    /// How many contiguous UTF-16 units around `candidate` still match the issue's context snapshot
    /// (suffix-aligned before the range, prefix-aligned after it).
    private static func contextScore(_ candidate: NSRange, in ns: NSString, issue: TextIssue) -> Int {
        var score = 0
        let before = issue.contextBefore as NSString
        var i = 0
        while i < before.length, candidate.location - 1 - i >= 0,
              ns.character(at: candidate.location - 1 - i)
                == before.character(at: before.length - 1 - i) {
            score += 1
            i += 1
        }
        let after = issue.contextAfter as NSString
        var j = 0
        while j < after.length, NSMaxRange(candidate) + j < ns.length,
              ns.character(at: NSMaxRange(candidate) + j) == after.character(at: j) {
            score += 1
            j += 1
        }
        return score
    }

    /// The first issue that overlaps `selection`, for the popup shown when the user selects a word.
    static func firstIssue(in issues: [TextIssue], overlapping selection: NSRange) -> TextIssue? {
        issues.first { NSIntersectionRange($0.range, selection).length > 0
            || (selection.length == 0 && NSLocationInRange(selection.location, $0.range)) }
    }
}
