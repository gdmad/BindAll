import Foundation
import NaturalLanguage

/// On-device semantic re-ranker for autocomplete (variant C). Embeds the context (the words before
/// the caret) and each candidate word with Apple's `NLContextualEmbedding` (the Cyrillic script
/// model covers Russian) and scores candidates by cosine similarity between the pooled vectors.
///
/// Fully on-device after the one-time OS asset download (`requestAssets`); until the model is
/// loaded `similarity` returns nil and callers fall back to the pool order. All model work runs on a
/// serial queue (the framework is not documented as thread-safe); result vectors are cached so
/// repeated words/contexts are cheap.
final class SemanticRanker {
    static let shared = SemanticRanker()

    private let embedQueue = DispatchQueue(label: "com.bindall.autocomplete.semantic", qos: .userInitiated)
    private let lock = NSLock()
    private var model: NLContextualEmbedding?
    private var assetsRequested = false
    /// Lowercased text -> pooled vector. Bounded: cleared when it grows too large.
    private var cache: [String: [Double]] = [:]
    private static let cacheLimit = 5000

    /// Kicks the model load on a background queue so the first keystroke does not pay for it.
    func warmup() {
        embedQueue.async { [weak self] in _ = self?.readyModel() }
    }

    /// Cosine similarity (0...1) between `context` and a candidate `word`, or nil when the model is
    /// not ready. Thread-safe.
    func similarity(context: String, candidate: String) -> Double? {
        guard let cv = vector(for: context), let wv = vector(for: candidate) else { return nil }
        return Self.cosine(cv, wv)
    }

    /// Pooled (token-length-weighted mean) embedding vector for `text`, or nil when unavailable.
    /// Thread-safe. Long inputs are truncated by the model itself (`maximumSequenceLength`).
    func vector(for text: String) -> [Double]? {
        let key = text.lowercased()
        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        var result: [Double]?
        embedQueue.sync {
            guard let model = readyModel() else { return }
            result = Self.pooledVector(of: text, model: model)
        }
        if let vec = result {
            lock.lock()
            if cache.count >= Self.cacheLimit { cache.removeAll(keepingCapacity: true) }
            cache[key] = vec
            lock.unlock()
        }
        return result
    }

    // MARK: - Model lifecycle

    /// Returns the loaded Cyrillic model, attempting a synchronous load when assets are already on
    /// disk and kicking an async asset download otherwise. Call on `embedQueue`.
    private func readyModel() -> NLContextualEmbedding? {
        lock.lock()
        if let m = model {
            lock.unlock()
            return m
        }
        lock.unlock()

        guard let candidate = NLContextualEmbedding(language: NLLanguage.russian) else {
            return nil
        }
        if candidate.hasAvailableAssets {
            do {
                try candidate.load()
                lock.lock()
                model = candidate
                lock.unlock()
                return candidate
            } catch {
                return nil
            }
        }

        // Assets missing: request the download once; until it completes callers see nil.
        lock.lock()
        let shouldRequest = !assetsRequested
        assetsRequested = true
        lock.unlock()
        if shouldRequest {
            candidate.requestAssets { [weak self] result, _ in
                guard result == .available else { return }
                do {
                    try candidate.load()
                    self?.lock.lock()
                    self?.model = candidate
                    self?.lock.unlock()
                } catch {}
            }
        }
        return nil
    }

    // MARK: - Pooling

    /// Length-weighted mean of the subword token vectors (longer tokens carry more weight).
    private static func pooledVector(of text: String, model: NLContextualEmbedding) -> [Double]? {
        guard let result = try? model.embeddingResult(for: text, language: .russian) else { return nil }
        let dim = Int(model.dimension)
        guard dim > 0 else { return nil }
        var sum = [Double](repeating: 0, count: dim)
        var weight = 0.0
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, range in
            let w = Double(text.distance(from: range.lowerBound, to: range.upperBound))
            let n = min(dim, vector.count)
            for i in 0..<n { sum[i] += vector[i] * w }
            weight += w
            return true
        }
        guard weight > 0 else { return nil }
        return sum.map { $0 / weight }
    }

    static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        var dot = 0.0, na = 0.0, nb = 0.0
        let n = min(a.count, b.count)
        for i in 0..<n {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (sqrt(na) * sqrt(nb))
    }
}
