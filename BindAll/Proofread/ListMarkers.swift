import Foundation

/// List markers glued to their item. Slack reports a numbered item as "1.Buy bread" and a bulleted
/// one as "\u{E506}Buy bread" -- the marker and the text with nothing between them -- so LanguageTool
/// read "1.Buy" as a sentence that ends without a space and flagged every item.
enum ListMarkers {
    /// Offsets, one per line, right after a marker that starts the line and runs straight into a
    /// letter: where the check needs a space. "1.5 kg" and "-5" are not markers (a digit follows),
    /// nor is "1. Buy" (it is already separated).
    static func markerEnds(in text: String) -> [Int] {
        let ns = text as NSString
        var out: [Int] = []
        var lineStart = 0
        while lineStart < ns.length {
            let lineEnd = ns.range(of: "\n", options: [.literal],
                                   range: NSRange(location: lineStart, length: ns.length - lineStart))
            let end = lineEnd.location == NSNotFound ? ns.length : lineEnd.location
            if let markerEnd = markerEnd(in: ns, from: lineStart, to: end),
               markerEnd < end, let next = UnicodeScalar(ns.character(at: markerEnd)),
               CharacterSet.letters.contains(next) {
                out.append(markerEnd)
            }
            lineStart = end + 1
        }
        return out
    }

    /// The end of a marker at `start`: up to three digits or one Latin letter followed by "." or ")",
    /// or one bullet character.
    private static func markerEnd(in ns: NSString, from start: Int, to end: Int) -> Int? {
        guard start < end, let first = UnicodeScalar(ns.character(at: start)) else { return nil }
        if bullets.contains(first) || (0xE000...0xF8FF).contains(first.value) { return start + 1 }
        var index = start
        if CharacterSet.decimalDigits.contains(first) {
            while index < end, index - start < 3, let c = UnicodeScalar(ns.character(at: index)),
                  CharacterSet.decimalDigits.contains(c) { index += 1 }
        } else if latinLetters.contains(first) {
            index += 1
        } else {
            return nil
        }
        guard index < end, let closer = UnicodeScalar(ns.character(at: index)), closers.contains(closer) else {
            return nil
        }
        return index + 1
    }

    /// Slack's own bullet is a private-use glyph (U+E506); the rest are the usual typed ones.
    private static let bullets = CharacterSet(charactersIn: "•◦▪▫‣●○■□·–—-*")
    private static let closers = CharacterSet(charactersIn: ".)")
    private static let latinLetters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
}
