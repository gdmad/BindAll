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

    /// Up to `limit` suggestions for `partial`: learned words first (already frequency-ordered), then
    /// dictionary completions that extend it, then spelling guesses. `language` is "auto" or a BCP-47
    /// code. Each result is recased to the typed word's case pattern. Main-thread only (NSSpellChecker).
    static func suggestions(for partial: String, language: String, learned: [String], limit: Int) -> [String] {
        guard !partial.isEmpty else { return [] }
        let lower = partial.lowercased()
        var out: [String] = []

        func addExtending(_ word: String) {
            guard word.count > partial.count, word.lowercased().hasPrefix(lower),
                  !out.contains(where: { $0.lowercased() == word.lowercased() }) else { return }
            out.append(word)
        }

        for word in learned {
            addExtending(word)
            if out.count >= limit { break }
        }

        if out.count < limit {
            let checker = NSSpellChecker.shared
            let lang: String
            if language != "auto", !language.isEmpty {
                lang = language
            } else {
                checker.automaticallyIdentifiesLanguages = true
                lang = checker.language()
            }
            let range = NSRange(location: 0, length: (partial as NSString).length)
            for candidate in (checker.completions(forPartialWordRange: range, in: partial,
                                                  language: lang, inSpellDocumentWithTag: 0) ?? []) {
                addExtending(candidate)
                if out.count >= limit { break }
            }
            if out.count < limit {
                for guess in (checker.guesses(forWordRange: range, in: partial,
                                              language: lang, inSpellDocumentWithTag: 0) ?? []) {
                    if guess.lowercased() != lower, !out.contains(where: { $0.lowercased() == guess.lowercased() }) {
                        out.append(guess)
                    }
                    if out.count >= limit { break }
                }
            }
        }

        // Recase to the typed word's case pattern, de-duplicating again.
        var result: [String] = []
        for word in out {
            let cased = recased(word, like: partial)
            if !result.contains(cased) { result.append(cased) }
        }
        return Array(result.prefix(limit))
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
