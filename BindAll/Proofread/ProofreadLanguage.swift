import Foundation

/// Decides which language to check text in. Kept free of NaturalLanguage imports: the caller detects
/// the language (via `LanguageDetector` in TranslationService.swift) and passes the result in, so
/// this logic stays pure and testable.
enum ProofreadLanguage {
    static let autoTag = "auto"

    /// Resolves the language to check `text` in.
    /// - Parameters:
    ///   - setting: a BCP-47 code, or "auto".
    ///   - detected: what language detection returned for `text`, if anything.
    ///   - fallback: used when the setting is "auto" and detection failed.
    static func resolve(text: String, setting: String, detected: String?, fallback: String = "ru") -> String {
        guard setting == autoTag else { return setting }
        guard let detected, !detected.isEmpty else { return fallback }
        return disambiguateCyrillic(text, candidate: detected, preferred: fallback)
    }

    /// Language detection leans on statistics, and on short Cyrillic text it routinely returns a
    /// neighbouring language (uk/bg/mk/be) for what is actually Russian. Those languages have letters
    /// Russian does not, so their absence is good evidence the guess is wrong: fall back to the
    /// user's preferred Cyrillic language instead. Checking Russian text against Ukrainian
    /// dictionaries would flag nearly every word.
    static func disambiguateCyrillic(_ text: String, candidate: String, preferred: String) -> String {
        let cyrillic: Set<String> = ["ru", "uk", "bg", "mk", "be", "sr"]
        let base = baseCode(candidate)
        guard cyrillic.contains(base), cyrillic.contains(baseCode(preferred)), base != baseCode(preferred) else {
            return candidate
        }
        // Letters that exist in uk/be/mk/sr/bg but not in Russian.
        let distinctive = CharacterSet(charactersIn: "іїєґўѓќљњџѕѐѝ")
        let lowered = text.lowercased()
        let hasDistinctive = lowered.unicodeScalars.contains { distinctive.contains($0) }
        return hasDistinctive ? candidate : preferred
    }

    /// "en-US" -> "en".
    static func baseCode(_ code: String) -> String {
        String(code.split(separator: "-").first ?? Substring(code)).lowercased()
    }

    /// NSSpellChecker only ships grammar rules for English and Spanish; asking for `.grammar` in any
    /// other language is a wasted pass that returns nothing.
    static func spellCheckerSupportsGrammar(_ code: String) -> Bool {
        ["en", "es"].contains(baseCode(code))
    }
}
