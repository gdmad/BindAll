import Foundation

/// Line breaks that are on screen but missing from a field's text. Slack (Chromium) reports a
/// list's items, quotes and code blocks glued together in `AXValue` -- "Buy bread.Call mom" -- so
/// LanguageTool saw one run-on sentence and flagged the next item's first word ("add a space
/// between sentences"). The check runs on the text with these breaks put back; the issues are then
/// mapped back onto the field's own text, which is what every AX call is indexed by.
struct HiddenBreaks: Equatable {
    /// UTF-16 offsets into the field's text, ascending. A break sits *before* the character there.
    let offsets: [Int]
    /// Where a space is put back instead: right after a list item's number or bullet, which Slack
    /// glues to the item ("1.Buy bread", "\u{E506}Buy bread"). See `ListMarkers`.
    let spaces: [Int]

    static let none = HiddenBreaks(offsets: [])

    init(offsets: [Int], spaces: [Int] = []) {
        self.offsets = Array(Set(offsets)).sorted()
        self.spaces = Array(Set(spaces).subtracting(offsets)).sorted()
    }

    var isEmpty: Bool { offsets.isEmpty && spaces.isEmpty }

    func addingSpaces(_ more: [Int]) -> HiddenBreaks {
        HiddenBreaks(offsets: offsets, spaces: spaces + more)
    }

    /// Every inserted character, by its offset in the field's text, ascending.
    private var insertions: [(offset: Int, character: String)] {
        (offsets.map { ($0, "\n") } + spaces.map { ($0, " ") }).sorted { $0.0 < $1.0 }
    }

    /// The text LanguageTool should see: the field's text with a newline at every hidden break and
    /// a space after every glued list marker.
    func checkText(_ text: String) -> String {
        guard !isEmpty else { return text }
        let ns = text as NSString
        var out = ""
        var start = 0
        for insertion in insertions where insertion.offset > start && insertion.offset < ns.length {
            out += ns.substring(with: NSRange(location: start, length: insertion.offset - start)) + insertion.character
            start = insertion.offset
        }
        return out + ns.substring(from: start)
    }

    /// Moves issues found in `checkText(text)` back onto `text`. An issue that spans an inserted
    /// break is dropped: its fix would have to edit across two blocks of the field. The snapshot of
    /// the original and its surroundings is retaken from `text`, because it is compared against
    /// what the app itself reports and must not contain the newlines that are only ours.
    func mapBack(_ issues: [TextIssue], to text: String) -> [TextIssue] {
        guard !isEmpty else { return issues }
        let ns = text as NSString
        // Positions of the inserted characters in check-text coordinates.
        let inserted = insertions.enumerated().map { $0.element.offset + $0.offset }
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

    /// Where each piece of a field's text sits in that text, or nil for a piece that is not in it.
    /// Chromium reports a bulleted list's markers ("•", "1.") as text elements of their own while
    /// leaving them out of the field's value, and a link can add text of its own; requiring the
    /// pieces to add up to the value exactly is what made the whole search give up on such fields.
    /// Each piece is looked for at the cursor or a little past it; one that is not found is skipped.
    static func align(pieces: [String], in text: String, lookahead: Int = 64) -> [Int?] {
        let ns = text as NSString
        var cursor = 0
        return pieces.map { piece in
            let length = (piece as NSString).length
            guard length > 0, cursor < ns.length else { return nil }
            let window = NSRange(location: cursor, length: min(ns.length - cursor, lookahead + length))
            let found = ns.range(of: piece, options: [.literal], range: window)
            guard found.location != NSNotFound else { return nil }
            cursor = NSMaxRange(found)
            return found.location
        }
    }

    /// Where two pieces that sit back to back in `text` meet with nothing between them, and the
    /// second starts on a new line. `startsNewLine(previous, next)` gets the two pieces' indices.
    /// Pieces with whitespace at the seam need no break: the text already separates them.
    static func find(pieces: [String], in text: String,
                     startsNewLine: (_ previous: Int, _ next: Int) -> Bool) -> HiddenBreaks {
        let starts = align(pieces: pieces, in: text)
        var offsets: [Int] = []
        var previous: (index: Int, end: Int)?
        for (index, start) in starts.enumerated() {
            guard let start else { continue }
            defer { previous = (index, start + (pieces[index] as NSString).length) }
            guard let prev = previous, prev.end == start,
                  let first = pieces[index].unicodeScalars.first,
                  let last = pieces[prev.index].unicodeScalars.last,
                  !CharacterSet.whitespacesAndNewlines.contains(first),
                  !CharacterSet.whitespacesAndNewlines.contains(last),
                  startsNewLine(prev.index, index) else { continue }
            offsets.append(start)
        }
        return HiddenBreaks(offsets: offsets)
    }

    /// Places in `issue` that could be a line break the field hides: where the issue begins, when its
    /// fix inserts a space ("add a space between sentences"), and inside it wherever a lowercase
    /// letter or closing punctuation runs straight into a capital or a digit ("breadCall"). Each is
    /// the offset of the character after the possible break; the caller checks them on screen.
    static func seamCandidates(of issue: TextIssue, in text: String) -> [Int] {
        let ns = text as NSString
        let start = issue.range.location
        let end = min(NSMaxRange(issue.range), ns.length)
        var out: [Int] = []
        if start > 0, let fix = issue.replacements.first, fix.first?.isWhitespace == true,
           issue.original.first?.isWhitespace == false {
            out.append(start)
        }
        guard end - start > 1 else { return out }
        for offset in (start + 1)..<end {
            guard let before = UnicodeScalar(ns.character(at: offset - 1)),
                  let after = UnicodeScalar(ns.character(at: offset)) else { continue }
            let closesRun = CharacterSet.lowercaseLetters.contains(before) || closingPunctuation.contains(before)
            let opensRun = CharacterSet.uppercaseLetters.contains(after) || CharacterSet.decimalDigits.contains(after)
            if closesRun && opensRun { out.append(offset) }
        }
        return out
    }

    private static let closingPunctuation = CharacterSet(charactersIn: ".,:;!?)]»\"'")
}
