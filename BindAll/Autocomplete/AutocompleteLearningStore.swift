import Foundation

/// Learns the words the user types/accepts and which words tend to follow which, to rank suggestions
/// and predict the next word. Persisted locally; contains only words (never API keys or full text).
/// Used only from the main thread (the autocomplete controller and Settings).
final class AutocompleteLearningStore {
    static let shared = AutocompleteLearningStore()

    private struct Model: Codable {
        var wordCounts: [String: Int] = [:]
        var bigrams: [String: [String: Int]] = [:] // lowercased previous word -> (next word -> count)
    }

    private var model = Model()
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
    }

    var wordCount: Int { model.wordCounts.count }

    /// Records a completed word and, when known, the word that preceded it.
    func record(word: String, after previous: String?) {
        guard word.count >= 2, word.allSatisfy({ $0.isLetter }) else { return }
        model.wordCounts[word, default: 0] += 1
        if let previous, !previous.isEmpty {
            model.bigrams[previous.lowercased(), default: [:]][word, default: 0] += 1
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

    /// Most likely words to follow `previous`, most-used first.
    func nextWords(after previous: String, limit: Int) -> [String] {
        guard let following = model.bigrams[previous.lowercased()] else { return [] }
        return following.sorted { $0.value > $1.value }.prefix(limit).map { $0.key }
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
