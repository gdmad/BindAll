import Foundation
import os

/// Learns the words the user types/accepts and which words tend to follow which, to rank suggestions
/// and predict the next word. Persisted locally; contains only words (never API keys or full text).
///
/// Thread-safe: the autocomplete controller reads it from a background work queue while the Settings
/// management UI touches it from the main thread. All access to the mutable `model` is serialized with
/// `lock`, and disk writes are pushed to a background queue so callers never block on I/O.
final class AutocompleteLearningStore {
    static let shared = AutocompleteLearningStore()

    /// Guards `model` (and `seedBigrams` during setup). Held only for cheap in-memory work; disk I/O
    /// happens off-lock on `ioQueue`.
    private var lock = os_unfair_lock()
    private func withLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return body()
    }
    /// Serializes disk writes so concurrent `save()` calls never interleave or block the caller.
    private let ioQueue = DispatchQueue(label: "com.bindall.autocomplete.store.io", qos: .utility)

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

    var wordCount: Int { withLock { model.wordCounts.count } }

    /// Records a completed word with up to two preceding words (for bigram + trigram learning).
    /// Learned words are stored lowercased so case variants ("Привет"/"привет") do not split; the
    /// engine recases current-word completions to the typed prefix. (Custom words keep their case.)
    func record(word: String, prev1: String?, prev2: String?) {
        let w = word.lowercased()
        guard w.count >= 2, w.allSatisfy({ $0.isLetter }) else { return }
        let snapshot = withLock { () -> Model in
            model.wordCounts[w, default: 0] += 1
            if let p1 = prev1, !p1.isEmpty {
                model.bigrams[p1.lowercased(), default: [:]][w, default: 0] += 1
                if let p2 = prev2, !p2.isEmpty {
                    model.trigrams[Self.trigramKey(p2, p1), default: [:]][w, default: 0] += 1
                }
            }
            pruneLocked()
            return model
        }
        persist(snapshot)
    }

    /// Words typed/accepted fewer than this many times haven't been confirmed as real words yet
    /// (as opposed to one-off typos) and are excluded from suggestions, though still recorded.
    /// Pinned custom words (weight 1_000_000) are always exempt.
    private let minSurfaceCount = 2

    /// Learned words extending `partial` (case-insensitive), most-used first.
    func completions(matching partial: String, limit: Int) -> [String] {
        let lower = partial.lowercased()
        return withLock {
            model.wordCounts
                .filter { $0.key.count > partial.count && $0.key.lowercased().hasPrefix(lower)
                         && $0.value >= minSurfaceCount }
                .sorted { $0.value > $1.value }
                .prefix(limit)
                .map { $0.key }
        }
    }

    /// Most likely next words, using a trigram -> bigram backoff. `prev1` is the immediately previous
    /// word; `prev2` the one before it (optional).
    func nextWords(prev1: String, prev2: String?, limit: Int) -> [String] {
        withLock {
            var out: [String] = []
            func add(_ following: [String: Int]?, minCount: Int) {
                guard let following else { return }
                for (word, count) in following.sorted(by: { $0.value > $1.value }) {
                    guard count >= minCount else { continue }
                    if !out.contains(word) { out.append(word) }
                    if out.count >= limit { break }
                }
            }
            if let p2 = prev2, !p2.isEmpty {
                add(model.trigrams[Self.trigramKey(p2, prev1)], minCount: minSurfaceCount)
            }
            if out.count < limit {
                add(model.bigrams[prev1.lowercased()], minCount: minSurfaceCount)
            }
            if out.count < limit {
                add(seedBigrams[prev1.lowercased()], minCount: 1) // bundled seed is pre-vetted, exempt
            }
            return Array(out.prefix(limit))
        }
    }

    /// All learned words, most-used first (for the management UI).
    func entries() -> [(word: String, count: Int)] {
        withLock { model.wordCounts.sorted { $0.value > $1.value }.map { ($0.key, $0.value) } }
    }

    /// Adds a custom word pinned to the top of suggestions (very high weight).
    func add(custom word: String) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 1, trimmed.allSatisfy({ $0.isLetter }) else { return }
        let snapshot = withLock { () -> Model in
            model.wordCounts[trimmed] = max(model.wordCounts[trimmed] ?? 0, 1_000_000)
            return model
        }
        persist(snapshot)
    }

    func remove(word: String) {
        let snapshot = withLock { () -> Model in
            model.wordCounts[word] = nil
            for key in model.bigrams.keys {
                model.bigrams[key]?[word] = nil
                if model.bigrams[key]?.isEmpty == true { model.bigrams[key] = nil }
            }
            for key in model.trigrams.keys {
                model.trigrams[key]?[word] = nil
                if model.trigrams[key]?.isEmpty == true { model.trigrams[key] = nil }
            }
            return model
        }
        persist(snapshot)
    }

    func clear() {
        withLock { model = Model() }
        ioQueue.async { [fileURL] in try? FileManager.default.removeItem(at: fileURL) }
    }

    // MARK: - Persistence

    /// Caps the learned-word map. Caller must already hold `lock`.
    private func pruneLocked() {
        guard model.wordCounts.count > maxWords else { return }
        let kept = model.wordCounts.sorted { $0.value > $1.value }.prefix(maxWords)
        model.wordCounts = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(Model.self, from: data) else { return }
        model = decoded
        normalizeCase()
    }

    /// One-time cleanup of pre-existing data: lowercase non-pinned learned words and all n-gram "next"
    /// values so case variants merge. Pinned custom words (count >= 1_000_000) keep their case.
    private func normalizeCase() {
        func lowerNextValues(_ dict: [String: [String: Int]]) -> (result: [String: [String: Int]], changed: Bool) {
            var out: [String: [String: Int]] = [:]
            var changed = false
            for (key, inner) in dict {
                var merged: [String: Int] = [:]
                for (word, count) in inner {
                    let lw = word.lowercased()
                    if lw != word { changed = true }
                    merged[lw, default: 0] += count
                }
                out[key] = merged
            }
            return (out, changed)
        }

        var changed = false
        var counts: [String: Int] = [:]
        for (word, count) in model.wordCounts {
            let key = count >= 1_000_000 ? word : word.lowercased()
            if key != word { changed = true }
            counts[key, default: 0] += count
        }
        model.wordCounts = counts

        let (bg, bgChanged) = lowerNextValues(model.bigrams)
        model.bigrams = bg
        let (tg, tgChanged) = lowerNextValues(model.trigrams)
        model.trigrams = tg

        if changed || bgChanged || tgChanged { persist(model) }
    }

    /// Encodes `snapshot` and writes it atomically off the caller's thread, so learning a word never
    /// blocks typing on disk I/O. Writes are serialized on `ioQueue`.
    private func persist(_ snapshot: Model) {
        ioQueue.async { [fileURL] in
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
