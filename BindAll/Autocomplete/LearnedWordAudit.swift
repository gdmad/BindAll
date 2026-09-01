import Foundation

/// Finds learned words that look like typos.
///
/// Autocomplete learns whatever gets typed, so a word mistyped twice clears `minSurfaceCount` and
/// starts being suggested like any other. The store cannot tell the difference on its own -- only a
/// dictionary can -- so this offers candidates for review; deleting is always the user's call.
///
/// The dictionary check arrives as a closure, which keeps this pure (and testable without AppKit).
enum LearnedWordAudit {
    /// The weight `AutocompleteLearningStore.add(custom:)` gives a word the user pinned by hand.
    static let pinnedWeight = 1_000_000
    /// Shorter words are too easy to mistake for abbreviations and initials worth keeping.
    static let minLength = 3

    /// Learned words the dictionary does not know, least-used first: the ones at the top have been
    /// typed once or twice and are the safest to drop. Pinned words are never suspects -- the user
    /// added them precisely because no dictionary has them.
    static func suspects(in entries: [(word: String, count: Int)],
                         isKnown: (String) -> Bool) -> [(word: String, count: Int)] {
        entries
            .filter { $0.count < pinnedWeight && $0.word.count >= minLength && !isKnown($0.word) }
            .sorted { $0.count == $1.count ? $0.word < $1.word : $0.count < $1.count }
    }
}
