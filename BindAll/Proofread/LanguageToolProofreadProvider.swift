import Foundation

/// Finds issues by asking a LanguageTool server. This is the only source of issues: it is the one
/// engine with real Russian grammar, and unlike a spell checker it reads the sentence, so it catches
/// agreement and punctuation rather than just unknown words.
///
/// An actor because it owns the cache: checks are kicked off from the main thread but complete on
/// whatever thread URLSession finishes on.
///
/// Text is sent a paragraph at a time and cached by paragraph text, so editing one sentence costs one
/// request and re-checking unchanged text costs none. That matters for the select-a-word popup, which
/// re-checks on every selection.
actor LanguageToolProofreadProvider {
    private var engine: LanguageToolEngine
    /// BCP-47 code, or "auto" to let the server detect it.
    private var language: String
    private let cache = ProofreadCache()

    init(engine: LanguageToolEngine, language: String) {
        self.engine = engine
        self.language = language
    }

    /// Applies new settings. Server or language changes invalidate everything we cached.
    func configure(engine: LanguageToolEngine, language: String) {
        guard engine.baseURL != self.engine.baseURL || language != self.language else { return }
        self.engine = engine
        self.language = language
        cache.clear()
    }

    /// Checks `text`, returning issues in `text`'s own coordinates.
    func check(_ text: String) async throws -> [TextIssue] {
        let paragraphs = TextSegmenter.paragraphs(of: text)
        var out: [TextIssue] = []
        for paragraph in paragraphs where TextSegmenter.isCheckable(paragraph) {
            let local: [TextIssue]
            if let cached = cache.issues(for: paragraph) {
                local = cached
            } else {
                let matches = try await engine.check(paragraph.text, languageOverride: resolved(paragraph.text))
                local = LanguageToolEngine.issues(from: matches, text: paragraph.text)
                cache.store(local, for: paragraph)
            }
            out += ProofreadCache.rebase(local, to: paragraph.range.location)
        }
        cache.prune(keeping: paragraphs)
        return IssueMerger.merge(out)
    }

    /// The server accepts "auto", but its guess on short Cyrillic text drifts to uk/bg. An explicit
    /// setting is passed through; for "auto" we detect locally and disambiguate, and fall back to
    /// letting the server decide when detection gives us nothing.
    private func resolved(_ text: String) -> String? {
        guard language == ProofreadLanguage.autoTag || language.isEmpty else { return language }
        guard let detected = LanguageDetector.detect(text)?.languageCode?.identifier else { return nil }
        return ProofreadLanguage.resolve(text: text, setting: ProofreadLanguage.autoTag, detected: detected)
    }
}
