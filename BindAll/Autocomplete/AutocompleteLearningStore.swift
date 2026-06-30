import Foundation

/// Learns the words the user types/accepts and which words tend to follow which, to rank suggestions
/// and predict the next word. Persisted locally; contains only words (never API keys or full text).
/// Used only from the main thread (the autocomplete controller and Settings).
final class AutocompleteLearningStore {
    static let shared = AutocompleteLearningStore()

    private struct Model: Codable {
        var wordCounts: [String: Int] = [:]
        var bigrams: [String: [String: Int]] = [:]   // lowercased prev word -> (next -> count)
        var trigrams: [String: [String: Int]] = [:]  // "w2\tw1" (lowercased) -> (next -> count)

        init() {}
        // Resilient: an older file without trigrams still loads.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            wordCounts = try c.decodeIfPresent([String: Int].self, forKey: .wordCounts) ?? [:]
            bigrams = try c.decodeIfPresent([String: [String: Int]].self, forKey: .bigrams) ?? [:]
            trigrams = try c.decodeIfPresent([String: [String: Int]].self, forKey: .trigrams) ?? [:]
        }
    }

    private static func trigramKey(_ w2: String, _ w1: String) -> String {
        w2.lowercased() + "\t" + w1.lowercased()
    }

    private var model = Model()
    /// Bundled seed bigrams (Russian only) used as a final next-word backoff. Read-only.
    private var seedBigrams: [String: [String: Int]] = [:]
    private let fileURL: URL
    private let maxWords = 5000

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = base.appendingPathComponent("BindAll", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("autocomplete.json")
        }
        load()
        loadSeed()
    }

    /// Loads the bundled Russian bigram seed (tab-separated: prev, next, freq). Missing file is fine.
    private func loadSeed() {
        guard let url = Bundle.main.url(forResource: "ru_bigrams", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        var seed: [String: [String: Int]] = [:]
        for line in text.split(separator: "\n") {
            let cols = line.split(separator: "\t")
            guard cols.count >= 3, let freq = Int(cols[2]) else { continue }
            seed[String(cols[0]), default: [:]][String(cols[1])] = freq
        }
        seedBigrams = seed
    }

    var wordCount: Int { model.wordCounts.count }

    /// Records a completed word with up to two preceding words (for bigram + trigram learning).
    func record(word: String, prev1: String?, prev2: String?) {
        guard word.count >= 2, word.allSatisfy({ $0.isLetter }) else { return }
        model.wordCounts[word, default: 0] += 1
        if let p1 = prev1, !p1.isEmpty {
            model.bigrams[p1.lowercased(), default: [:]][word, default: 0] += 1
            if let p2 = prev2, !p2.isEmpty {
                model.trigrams[Self.trigramKey(p2, p1), default: [:]][word, default: 0] += 1
            }
        }
        prune()
        save()
    }

    /// Learned words extending `partial` (case-insensitive), most-used first.
    func completions(matching partial: String, limit: Int) -> [String] {
        let lower = partial.lowercased()
        return model.wordCounts
            .filter { $0.key.count > partial.count && $0.key.lowercased().hasPrefix(lower) }
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { $0.key }
    }

    /// Most likely next words, using a trigram -> bigram backoff. `prev1` is the immediately previous
    /// word; `prev2` the one before it (optional).
    func nextWords(prev1: String, prev2: String?, limit: Int) -> [String] {
        var out: [String] = []
        func add(_ following: [String: Int]?) {
            guard let following else { return }
            for (word, _) in following.sorted(by: { $0.value > $1.value }) {
                if !out.contains(word) { out.append(word) }
                if out.count >= limit { break }
            }
        }
        if let p2 = prev2, !p2.isEmpty {
            add(model.trigrams[Self.trigramKey(p2, prev1)])
        }
        if out.count < limit {
            add(model.bigrams[prev1.lowercased()])
        }
        if out.count < limit {
            add(seedBigrams[prev1.lowercased()]) // bundled Russian seed (lowest priority)
        }
        return Array(out.prefix(limit))
    }

    /// All learned words, most-used first (for the management UI).
    func entries() -> [(word: String, count: Int)] {
        model.wordCounts.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    /// Adds a custom word pinned to the top of suggestions (very high weight).
    func add(custom word: String) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 1, trimmed.allSatisfy({ $0.isLetter }) else { return }
        model.wordCounts[trimmed] = max(model.wordCounts[trimmed] ?? 0, 1_000_000)
        save()
    }

    func remove(word: String) {
        model.wordCounts[word] = nil
        for key in model.bigrams.keys {
            model.bigrams[key]?[word] = nil
            if model.bigrams[key]?.isEmpty == true { model.bigrams[key] = nil }
        }
        for key in model.trigrams.keys {
            model.trigrams[key]?[word] = nil
            if model.trigrams[key]?.isEmpty == true { model.trigrams[key] = nil }
        }
        save()
    }

    func clear() {
        model = Model()
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Persistence

    private func prune() {
        guard model.wordCounts.count > maxWords else { return }
        let kept = model.wordCounts.sorted { $0.value > $1.value }.prefix(maxWords)
        model.wordCounts = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(Model.self, from: data) else { return }
        model = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(model) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
