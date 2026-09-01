import AppKit

/// Word suggestions backed by the system spell checker (`NSSpellChecker`), plus a pure helper for
/// extracting the word currently being typed. Used by the autocomplete feature.
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

    /// The up to `count` completed words immediately before the word being typed at
    /// `caretUTF16Offset`, lowercased, most recent first (`[0]` = the word just before the caret).
    /// Non-letter characters split tokens, so the words are the same units the learning store sees.
    /// Empty when there is no completed word before the caret.
    static func precedingWords(in text: String, caretUTF16Offset: Int, count: Int) -> [String] {
        let ns = text as NSString
        let caret = max(0, min(caretUTF16Offset, ns.length))
        var tokens: [String] = []
        var i = caret
        // Skip the partial word currently being typed.
        while i > 0 {
            guard let scalar = Unicode.Scalar(ns.character(at: i - 1)),
                  CharacterSet.letters.contains(scalar) else { break }
            i -= 1
        }
        // Walk further back, collecting completed letter words.
        while i > 0, tokens.count < count {
            while i > 0 {
                guard let scalar = Unicode.Scalar(ns.character(at: i - 1)),
                      !CharacterSet.letters.contains(scalar) else { break }
                i -= 1
            }
            let end = i
            while i > 0 {
                guard let scalar = Unicode.Scalar(ns.character(at: i - 1)),
                      CharacterSet.letters.contains(scalar) else { break }
                i -= 1
            }
            if i < end {
                tokens.append(ns.substring(with: NSRange(location: i, length: end - i)).lowercased())
            }
        }
        return tokens
    }

    private static let wordTerminators: Set<Character> = [".", ",", "!", "?", ";", ":",
                                                          ")", "]", "}", "\"", "»", "”", "…"]

    /// True for characters that close the word being typed, so it is complete and worth learning.
    /// Apostrophes, hyphens and digits are deliberately absent: they sit inside a token, and treating
    /// them as boundaries would learn "don" from "don't" or "co" from "co-founder".
    static func isWordTerminator(_ character: Character) -> Bool {
        wordTerminators.contains(character)
    }

    /// Which candidate pool and ranking a `Request` uses. `baseline` reproduces the original
    /// behavior exactly; the other modes gather the same learned + dictionary candidates and re-rank
    /// them with a scorer supplied by the caller (so this file stays free of the learning store and
    /// the embedding framework).
    enum Mode: String, CaseIterable {
        /// Original behavior: learned completions first (frequency order), then dictionary
        /// completions, then spelling guesses. Context is not consulted.
        case baseline
        /// Variant A/B: gather learned + dictionary completions into a larger pool, then rank it with
        /// `contextScorer` (previous-word n-gram evidence + frequency prior). Guesses are not used.
        case context
        /// Variant C: same pool, ranked with `semanticScorer` (context-embedding similarity blended
        /// with the frequency prior). Guesses are not used.
        case semantic
    }

    /// One evaluation of the completion engine. `learned` is the caller's frequency-ordered list of
    /// learned words extending `partial`. The scorer closures are optional: a nil scorer degrades the
    /// re-ranking modes to the pool's natural order (frequency, then dictionary).
    struct Request {
        var partial: String
        var languages: [String]   // BCP-47 codes to query; empty means auto-detect a single language
        var learned: [String]
        var limit: Int
        var mode: Mode = .baseline
        /// Higher is better; nil means no context information (falls back to the pool order).
        var contextScorer: ((String) -> Double)? = nil
        /// Higher is better; nil means semantic ranking is unavailable (falls back to the pool order).
        var semanticScorer: ((String) -> Double)? = nil
    }

    /// How many candidates are gathered before a re-ranking mode scores them. Large enough that the
    /// context/semantic ranking has real choices, small enough that NSSpellChecker never floods the
    /// pipeline (it can return hundreds of entries for short prefixes). Internal so the controller
    /// can size its learned-candidate request to match.
    static let reRankPoolLimit = 30

    /// Baseline convenience: original `suggestions(for:languages:learned:limit:)` behavior.
    static func suggestions(for partial: String, languages: [String], learned: [String], limit: Int) -> [String] {
        suggestions(request: Request(partial: partial, languages: languages, learned: learned, limit: limit))
    }

    /// Up to `request.limit` suggestions for the partial word, per `request.mode`. Each result is
    /// recased to the typed word's case pattern. Main-thread only (NSSpellChecker).
    static func suggestions(request: Request) -> [String] {
        guard !request.partial.isEmpty else { return [] }
        let lower = request.partial.lowercased()
        let limit = max(0, request.limit)
        var out: [String] = []

        func addExtending(_ word: String) {
            guard word.count > request.partial.count, word.lowercased().hasPrefix(lower),
                  !out.contains(where: { $0.lowercased() == word.lowercased() }) else { return }
            out.append(word)
        }
        func addCorrection(_ word: String) {
            guard word.lowercased() != lower,
                  !out.contains(where: { $0.lowercased() == word.lowercased() }) else { return }
            out.append(word)
        }
        func fillFromSpellChecker(stopAt: Int, includeGuesses: Bool) {
            let checker = NSSpellChecker.shared
            let langs: [String]
            if request.languages.isEmpty {
                checker.automaticallyIdentifiesLanguages = true
                langs = [checker.language()]
            } else {
                langs = request.languages
            }
            let range = NSRange(location: 0, length: (request.partial as NSString).length)
            // Completions first (across all chosen languages), then guesses.
            for lang in langs {
                for candidate in (checker.completions(forPartialWordRange: range, in: request.partial,
                                                      language: lang, inSpellDocumentWithTag: 0) ?? []) {
                    addExtending(candidate)
                    if out.count >= stopAt { break }
                }
                if out.count >= stopAt { break }
            }
            if includeGuesses && out.count < stopAt {
                for lang in langs {
                    for guess in (checker.guesses(forWordRange: range, in: request.partial,
                                                  language: lang, inSpellDocumentWithTag: 0) ?? []) {
                        addCorrection(guess)
                        if out.count >= stopAt { break }
                    }
                    if out.count >= stopAt { break }
                }
            }
        }

        switch request.mode {
        case .baseline:
            // Original pipeline, preserved exactly: learned first, dictionary, then guesses.
            for word in request.learned {
                addExtending(word)
                if out.count >= limit { break }
            }
            if out.count < limit {
                fillFromSpellChecker(stopAt: limit, includeGuesses: true)
            }

        case .context, .semantic:
            // Gather a pool larger than the visible limit so the re-ranking has real choices.
            let poolLimit = max(reRankPoolLimit, limit)
            for word in request.learned {
                addExtending(word)
                if out.count >= poolLimit { break }
            }
            if out.count < poolLimit {
                fillFromSpellChecker(stopAt: poolLimit, includeGuesses: false)
            }
            let scorer: (String) -> Double
            switch request.mode {
            case .context: scorer = { request.contextScorer?($0) ?? 0 }
            case .semantic: scorer = { request.semanticScorer?($0) ?? 0 }
            case .baseline: fatalError("unreachable")
            }
            // Stable sort by score descending: ties keep the pool order (frequency, then dictionary).
            let ranked = out.enumerated()
                .sorted { a, b in
                    let sa = scorer(a.element), sb = scorer(b.element)
                    return sa != sb ? sa > sb : a.offset < b.offset
                }
                .map { $0.element }
            out = ranked
        }

        // Recase to the typed word's case pattern, de-duplicating again.
        var result: [String] = []
        for word in out {
            let cased = recased(word, like: request.partial)
            if !result.contains(cased) { result.append(cased) }
        }
        return Array(result.prefix(limit))
    }

    /// Whether the dictionary knows `word`, in any of `languages` (empty = the auto-detected one).
    /// Used by the learned-word review to tell typos from real words. Like the rest of the
    /// `NSSpellChecker` work here, call it off the main thread: it is not cheap, and the review runs
    /// it over the whole learned vocabulary.
    static func isKnownWord(_ word: String, languages: [String]) -> Bool {
        let checker = NSSpellChecker.shared
        let langs: [String]
        if languages.isEmpty {
            checker.automaticallyIdentifiesLanguages = true
            langs = [checker.language()]
        } else {
            langs = languages
        }
        for lang in langs {
            let misspelled = checker.checkSpelling(of: word, startingAt: 0, language: lang,
                                                   wrap: false, inSpellDocumentWithTag: 0,
                                                   wordCount: nil)
            if misspelled.location == NSNotFound { return true }
        }
        return false
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
