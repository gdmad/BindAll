import Foundation

/// Line breaks that are on screen but missing from a field's text. Slack (Chromium) reports a
/// list's items, quotes and code blocks glued together in `AXValue` -- "Buy bread.Call mom" -- so
/// LanguageTool saw one run-on sentence and flagged the next item's first word ("add a space
/// between sentences"). The check runs on the text with these breaks put back; the issues are then
/// mapped back onto the field's own text, which is what every AX call is indexed by.
struct HiddenBreaks: Equatable {
    /// UTF-16 offsets into the field's text, ascending. A break sits *before* the character there.
    let offsets: [Int]

    static let none = HiddenBreaks(offsets: [])

    init(offsets: [Int]) {
        self.offsets = Array(Set(offsets)).sorted()
    }

    var isEmpty: Bool { offsets.isEmpty }

    /// The text LanguageTool should see: the field's text with a newline at every hidden break.
    func checkText(_ text: String) -> String {
        guard !offsets.isEmpty else { return text }
        let ns = text as NSString
        var out = ""
        var start = 0
        for offset in offsets where offset > start && offset < ns.length {
            out += ns.substring(with: NSRange(location: start, length: offset - start)) + "\n"
            start = offset
        }
        return out + ns.substring(from: start)
    }

    /// Moves issues found in `checkText(text)` back onto `text`. An issue that spans an inserted
    /// break is dropped: its fix would have to edit across two blocks of the field. The snapshot of
    /// the original and its surroundings is retaken from `text`, because it is compared against
    /// what the app itself reports and must not contain the newlines that are only ours.
    func mapBack(_ issues: [TextIssue], to text: String) -> [TextIssue] {
        guard !offsets.isEmpty else { return issues }
        let ns = text as NSString
        // Positions of the inserted newlines in check-text coordinates.
        let inserted = offsets.enumerated().map { $0.element + $0.offset }
        return issues.compactMap { issue in
            let start = issue.range.location
            let end = NSMaxRange(issue.range)
            if inserted.contains(where: { $0 >= start && $0 < end }) { return nil }
            let shift = inserted.filter { $0 < start }.count
            let range = NSRange(location: start - shift, length: issue.range.length)
            guard NSMaxRange(range) <= ns.length else { return nil }
            let beforeStart = max(0, range.location - TextIssue.contextSpan)
            let afterEnd = min(ns.length, NSMaxRange(range) + TextIssue.contextSpan)
            return TextIssue(
                range: range, kind: issue.kind, shortMessage: issue.shortMessage, message: issue.message,
                replacements: issue.replacements, ruleId: issue.ruleId, source: issue.source,
                original: ns.substring(with: range),
                contextBefore: ns.substring(with: NSRange(location: beforeStart, length: range.location - beforeStart)),
                contextAfter: ns.substring(with: NSRange(location: NSMaxRange(range), length: afterEnd - NSMaxRange(range))))
        }
    }

    /// Where two consecutive pieces of a field's text meet with nothing between them, and the second
    /// starts on a new line. `pieces` are the text leaves in reading order; `startsNewLine(i)` says
    /// whether piece `i` begins on a lower line than piece `i - 1` ends. Pieces that must not be
    /// glued (whitespace on either side of the seam) need no break: the text already separates them.
    static func find(pieces: [String], startsNewLine: (Int) -> Bool) -> HiddenBreaks {
        var offsets: [Int] = []
        var position = 0
        for (index, piece) in pieces.enumerated() {
            defer { position += (piece as NSString).length }
            guard index > 0, let first = piece.unicodeScalars.first,
                  let last = pieces[index - 1].unicodeScalars.last,
                  !CharacterSet.whitespacesAndNewlines.contains(first),
                  !CharacterSet.whitespacesAndNewlines.contains(last),
                  startsNewLine(index) else { continue }
            offsets.append(position)
        }
        return HiddenBreaks(offsets: offsets)
    }
}
