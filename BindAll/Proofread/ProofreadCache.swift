import Foundation

/// A paragraph of the checked text, with its range in the document (UTF-16).
struct Paragraph: Equatable {
    var range: NSRange
    var text: String
}

/// Splits text into paragraphs. Checking is scoped to paragraphs so that typing a new sentence only
/// re-checks the paragraph it is in, instead of sending the whole document to LanguageTool again.
enum TextSegmenter {
    /// Splits on newlines. Separators belong to the paragraph they terminate, so the paragraph
    /// ranges tile the whole string with no gaps and no overlaps.
    static func paragraphs(of text: String) -> [Paragraph] {
        let ns = text as NSString
        guard ns.length > 0 else { return [] }

        var out: [Paragraph] = []
        var start = 0
        var i = 0
        while i < ns.length {
            let c = ns.character(at: i)
            if c == 0x0A || c == 0x0D {
                // Treat CRLF as one separator.
                var end = i + 1
                if c == 0x0D, end < ns.length, ns.character(at: end) == 0x0A { end += 1 }
                let range = NSRange(location: start, length: end - start)
                out.append(Paragraph(range: range, text: ns.substring(with: range)))
                start = end
                i = end
                continue
            }
            i += 1
        }
        if start < ns.length {
            let range = NSRange(location: start, length: ns.length - start)
            out.append(Paragraph(range: range, text: ns.substring(with: range)))
        }
        return out
    }

    /// True when a paragraph is worth sending to a provider at all.
    static func isCheckable(_ p: Paragraph) -> Bool {
        !p.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Caches issues per paragraph text. The key is the paragraph's own text: unchanged paragraphs hit
/// the cache and only need their ranges rebased, so editing one paragraph costs one request.
final class ProofreadCache {
    private var entries: [String: [TextIssue]] = [:]

    /// Cached issues for `p`, in paragraph-local coordinates.
    func issues(for p: Paragraph) -> [TextIssue]? {
        entries[p.text]
    }

    /// Stores `issues` (paragraph-local coordinates) for `p`.
    func store(_ issues: [TextIssue], for p: Paragraph) {
        entries[p.text] = issues
    }

    /// Moves paragraph-local ranges into document coordinates.
    static func rebase(_ issues: [TextIssue], to offset: Int) -> [TextIssue] {
        issues.map { $0.withRange(NSRange(location: $0.range.location + offset, length: $0.range.length)) }
    }

    /// Forgets paragraphs that are no longer in the document, so the cache tracks the text rather
    /// than growing with every edit.
    func prune(keeping paragraphs: [Paragraph]) {
        let live = Set(paragraphs.map(\.text))
        entries = entries.filter { live.contains($0.key) }
    }

    func clear() {
        entries.removeAll()
    }

    var count: Int { entries.count }
}
