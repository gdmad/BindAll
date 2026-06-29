import AppKit

/// Word completion backed by the system spell checker (`NSSpellChecker`), plus a pure helper for
/// extracting the word currently being typed. Used by the experimental autocomplete feature.
enum AutocompleteEngine {
    /// The word being typed immediately to the left of the caret. Letters only; empty when the caret
    /// sits at a non-letter boundary (so nothing is suggested right after a space or punctuation).
    /// `caretUTF16Offset` is an offset into `text`'s UTF-16 view (matches AX selected-range location).
    static func partialWord(in text: String, caretUTF16Offset: Int) -> String {
        let ns = text as NSString
        let caret = max(0, min(caretUTF16Offset, ns.length))
        var start = caret
        while start > 0 {
            guard let scalar = Unicode.Scalar(ns.character(at: start - 1)),
                  CharacterSet.letters.contains(scalar) else { break }
            start -= 1
        }
        return ns.substring(with: NSRange(location: start, length: caret - start))
    }

    /// Top completion for `partial` that strictly extends it (case-insensitive prefix), or nil.
    /// Must be called on the main thread (NSSpellChecker is main-thread only).
    static func completion(for partial: String) -> String? {
        guard !partial.isEmpty else { return nil }
        let checker = NSSpellChecker.shared
        checker.automaticallyIdentifiesLanguages = true
        let range = NSRange(location: 0, length: (partial as NSString).length)
        let candidates = checker.completions(forPartialWordRange: range, in: partial,
                                             language: checker.language(),
                                             inSpellDocumentWithTag: 0) ?? []
        let lowerPartial = partial.lowercased()
        for candidate in candidates where candidate.count > partial.count
            && candidate.lowercased().hasPrefix(lowerPartial) {
            return candidate
        }
        return nil
    }
}
