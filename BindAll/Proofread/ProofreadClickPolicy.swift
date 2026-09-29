import Foundation

/// What a click in a text field should do about the fixes popup.
///
/// Pure decision logic on purpose: the awkward cases (a drag across an underlined word, a
/// double-click that selects it, a click into empty space) are painful to reproduce by hand in a
/// real editor, so they are covered by tests here instead of by trial and error in Slack.
enum ProofreadClickPolicy {
    enum Action: Equatable {
        /// Ask about the issue overlapping this range, checking the field first if needed.
        case probe(NSRange)
        /// Close the popup but keep the underlines: the click landed on nothing fixable.
        case dismiss
        /// Leave everything alone, popup included.
        case ignore
    }

    static func action(selection: NSRange, caret: Int, in text: String) -> Action {
        // A selection means the user is copying, formatting or about to retype that text. Editors
        // put their own controls over a selection -- Slack's formatting toolbar appears right on top
        // of it -- so opening the fixes popup here fights the app's own UI for the same few pixels,
        // whether the user selected one word or a whole paragraph. The fix stays one plain click
        // into the word away.
        guard selection.length == 0 else { return .ignore }
        guard let word = WordBoundary.wordRange(at: caret, in: text) else { return .dismiss }
        return .probe(word)
    }
}
