import AppKit

/// Word suggestions backed by the system spell checker (`NSSpellChecker`), plus a pure helper for
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

    /// Up to `limit` suggestions for `partial`: completions that extend it first, then spelling
    /// guesses (corrections) for variety. Must be called on the main thread (NSSpellChecker is
    /// main-thread only).
    static func suggestions(for partial: String, limit: Int = 5) -> [String] {
        guard !partial.isEmpty else { return [] }
        let checker = NSSpellChecker.shared
        checker.automaticallyIdentifiesLanguages = true
        let language = checker.language()
        let range = NSRange(location: 0, length: (partial as NSString).length)
        let lower = partial.lowercased()
        var out: [String] = []

        // Completions that extend the partial word.
        for candidate in (checker.completions(forPartialWordRange: range, in: partial,
                                              language: language, inSpellDocumentWithTag: 0) ?? []) {
            if candidate.count > partial.count, candidate.lowercased().hasPrefix(lower), !out.contains(candidate) {
                out.append(candidate)
                if out.count >= limit { return out }
            }
        }
        // Spelling guesses (corrections) for additional variety.
        for guess in (checker.guesses(forWordRange: range, in: partial,
                                      language: language, inSpellDocumentWithTag: 0) ?? []) {
            if guess.lowercased() != lower, !out.contains(guess) {
                out.append(guess)
                if out.count >= limit { break }
            }
        }

        // Recase each suggestion to the typed word's case pattern, de-duplicating again.
        var result: [String] = []
        for word in out {
            let cased = recased(word, like: partial)
            if !result.contains(cased) { result.append(cased) }
        }
        return result
    }

    /// Recases `candidate` to match the case pattern of `partial`: ALL CAPS, Capitalized first letter,
    /// or the candidate's own (dictionary) case for lowercase / mixed input.
    static func recased(_ candidate: String, like partial: String) -> String {
        let letters = partial.filter { $0.isLetter }
        guard !letters.isEmpty else { return candidate }
        if letters.count >= 2, letters == letters.uppercased(), letters != letters.lowercased() {
            return candidate.uppercased()
        }
        if let first = partial.first, first.isUppercase {
            return candidate.prefix(1).uppercased() + candidate.dropFirst()
        }
        return candidate
    }
}
