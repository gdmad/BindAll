import Foundation

/// How to turn what was typed into the accepted suggestion, without ever emptying the field.
///
/// Deleting the whole partial and retyping the full word (the old behaviour, always) briefly leaves
/// the field with nothing where the partial was. If that was the field's only content -- the first
/// word in an empty compose box -- some editors (Slack's Quill-based composer among them) react to
/// going empty by asynchronously rebuilding their content node, and the retyped word lands on the
/// stale one and never appears. Appending only the part the suggestion adds never passes through
/// that empty state, which is the common case anyway: a suggestion almost always continues what was
/// typed.
enum AutocompleteInsertion {
    enum Step: Equatable {
        /// The suggestion continues what was typed: type only the remainder.
        case append(String)
        /// No common prefix (the suggestion recases or otherwise rewrites the partial, or there was
        /// no partial to continue): delete `deleteCount` UTF-16 units and type the suggestion in full.
        case replace(deleteCount: Int, String)
    }

    static func plan(partial: String, word: String) -> Step {
        guard word.hasPrefix(partial) else {
            return .replace(deleteCount: (partial as NSString).length, word)
        }
        return .append(String(word.dropFirst(partial.count)))
    }
}
