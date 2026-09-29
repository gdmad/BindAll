import AppKit
import SwiftUI

/// One source of truth for how an issue kind is shown: the underline color, the popup dot, and the
/// symbol that carries the same distinction when the user cannot rely on color.
///
/// The palette is LanguageTool's own: red spelling, yellow grammar, green punctuation, blue style.
enum IssueKindStyle {
    static func nsColor(_ kind: IssueKind) -> NSColor {
        switch kind {
        case .spelling: return .systemRed
        case .grammar: return .systemYellow
        case .punctuation: return .systemGreen
        case .style: return .systemBlue
        }
    }

    static func color(_ kind: IssueKind) -> Color {
        Color(nsColor: nsColor(kind))
    }

    /// The kind in words, for assistive tech: the dot and the underline carry it by color alone.
    static func title(_ kind: IssueKind) -> String {
        switch kind {
        case .spelling: return "Spelling"
        case .grammar: return "Grammar"
        case .punctuation: return "Punctuation"
        case .style: return "Style"
        }
    }

    /// Shown instead of the plain dot when "Differentiate Without Color" is on.
    static func symbolName(_ kind: IssueKind) -> String {
        switch kind {
        case .spelling: return "textformat.abc.dottedunderline"
        case .grammar: return "text.book.closed"
        case .punctuation: return "quote.bubble"
        case .style: return "paintbrush"
        }
    }
}
