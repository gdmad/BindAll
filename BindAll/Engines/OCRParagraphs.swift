import CoreGraphics
import Foundation

/// Rebuilds paragraphs from OCR lines. Vision returns every line on screen separately, and the
/// translator then translated each one as a fragment ("Как" / "дела?" became "How" / "things?").
/// Lines that wrap within one paragraph are joined back into sentences first.
enum OCRParagraphs {
    struct Line: Equatable {
        let text: String
        /// Normalized image coordinates, origin bottom-left (as Vision reports them).
        let box: CGRect
    }

    /// A gap above this fraction of the line height, or a jump in the left edge, starts a new paragraph.
    static let gapRatio: CGFloat = 0.8
    static let indentRatio: CGFloat = 1.5

    static func join(_ lines: [Line]) -> String {
        var out = ""
        var previous: Line?
        for line in lines {
            let text = line.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            defer { previous = line }
            guard let prev = previous else {
                out = text
                continue
            }
            if continues(prev, with: line) {
                // A word hyphenated across the wrap is put back together without the hyphen.
                if out.hasSuffix("-"), let first = text.first, first.isLowercase {
                    out.removeLast()
                    out += text
                } else {
                    out += " " + text
                }
            } else {
                out += "\n" + text
            }
        }
        return out
    }

    /// Whether `line` wraps on from `previous` rather than starting a new paragraph.
    static func continues(_ previous: Line, with line: Line) -> Bool {
        let height = max(previous.box.height, line.box.height)
        guard height > 0 else { return false }
        let gap = previous.box.minY - line.box.maxY // y grows upwards
        guard gap >= -height / 2, gap < height * gapRatio else { return false }
        return abs(line.box.minX - previous.box.minX) < height * indentRatio
    }
}
