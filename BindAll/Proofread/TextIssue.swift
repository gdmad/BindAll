import Foundation

/// What kind of problem a `TextIssue` describes. Drives the badge colour in the panel and the
/// underline colour in the overlay.
enum IssueKind: String, Codable, CaseIterable {
    case spelling
    case grammar
    case punctuation
    case style
}

/// Which provider produced an issue. LanguageTool is the only source today; the case exists so the
/// model does not have to change if an LLM-backed style pass is added later.
enum IssueSource: String, Codable {
    case languageTool
    case llm
}

/// One problem found in the checked text, in a form both the panel and the overlay can render and
/// `IssueApplier` can act on.
///
/// `range` holds UTF-16 offsets, which is what both the Accessibility API and LanguageTool use
/// (the latter reports Java char indices, which are UTF-16 code units).
struct TextIssue: Identifiable, Equatable {
    /// Derived from the issue's identity rather than freshly generated, so that re-checking the same
    /// text yields the same ids and the SwiftUI list does not flicker or lose its selection.
    let id: String
    var range: NSRange
    var kind: IssueKind
    /// One line, for a list row.
    var shortMessage: String
    /// The full explanation, for the detail popover.
    var message: String
    /// Suggested fixes, best first. May be empty: some rules explain without offering a fix.
    var replacements: [String]
    var ruleId: String?
    var source: IssueSource
    /// The substring at `range` when the check ran. `IssueApplier` compares it against the field's
    /// current contents to detect that the text moved or changed before applying anything.
    var original: String

    init(range: NSRange, kind: IssueKind, shortMessage: String, message: String,
         replacements: [String], ruleId: String?, source: IssueSource, original: String) {
        self.id = Self.identity(source: source, ruleId: ruleId, range: range, original: original)
        self.range = range
        self.kind = kind
        self.shortMessage = shortMessage
        self.message = message
        self.replacements = replacements
        self.ruleId = ruleId
        self.source = source
        self.original = original
    }

    /// Rebuilds an issue with a new range, keeping everything else. Used when ranges shift after an
    /// applied fix, or when paragraph-local ranges are rebased into document coordinates.
    func withRange(_ newRange: NSRange) -> TextIssue {
        TextIssue(range: newRange, kind: kind, shortMessage: shortMessage, message: message,
                  replacements: replacements, ruleId: ruleId, source: source, original: original)
    }

    static func identity(source: IssueSource, ruleId: String?, range: NSRange, original: String) -> String {
        "\(source.rawValue)|\(ruleId ?? "")|\(range.location)|\(range.length)|\(original)"
    }
}
