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

    /// Applies new settings. Any change -- server, username, token or language -- invalidates the
    /// cache, since a different account or endpoint can return different issues. Comparing the whole
    /// engine (not just its URL) is what lets a credentials-only change actually take effect.
    func configure(engine: LanguageToolEngine, language: String) {
        guard engine != self.engine || language != self.language else { return }
        self.engine = engine
        self.language = language
        cache.clear()
    }

    /// Checks `text`, returning issues in `text`'s own coordinates.
    ///
    /// Paragraphs that have not changed since the last check come from the cache instantly; the
    /// changed ones are checked concurrently, so editing several paragraphs costs one round trip
    /// instead of one per paragraph. Results are re-ordered back into document order.
    func check(_ text: String) async throws -> [TextIssue] {
        let paragraphs = TextSegmenter.paragraphs(of: text)
        var results: [(index: Int, issues: [TextIssue])] = []
        try await withThrowingTaskGroup(of: (Int, [TextIssue]).self) { group in
            for (index, paragraph) in paragraphs.enumerated() where TextSegmenter.isCheckable(paragraph) {
                group.addTask {
                    let local: [TextIssue]
                    if let cached = await self.cachedIssues(for: paragraph) {
                        local = cached
                    } else {
                        let matches = try await self.engine.check(paragraph.text,
                                                                  languageOverride: await self.resolved(paragraph.text))
                        local = LanguageToolEngine.issues(from: matches, text: paragraph.text)
                        await self.storeIssues(local, for: paragraph)
                    }
                    return (index, local)
                }
            }
            for try await result in group {
                results.append(result)
            }
        }
        cache.prune(keeping: paragraphs)
        let rebased = results.sorted { $0.index < $1.index }
            .flatMap { ProofreadCache.rebase($0.issues, to: paragraphs[$0.index].range.location) }
        return IssueMerger.merge(rebased)
    }

    /// Cache reads/writes go through these so the concurrent check tasks serialize on the actor
    /// instead of touching the cache dictionary from several threads at once.
    private func cachedIssues(for paragraph: Paragraph) -> [TextIssue]? {
        cache.issues(for: paragraph)
    }

    private func storeIssues(_ issues: [TextIssue], for paragraph: Paragraph) {
        cache.store(issues, for: paragraph)
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
