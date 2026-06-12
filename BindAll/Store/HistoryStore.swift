import Foundation

/// One successful operation kept in history. API keys are never part of an entry.
struct HistoryEntry: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case action
        case translate
        case ocr
        case quick

        var label: String {
            switch self {
            case .action: return "Action"
            case .translate: return "Translate"
            case .ocr: return "OCR"
            case .quick: return "Quick"
            }
        }
    }

    var id: UUID = UUID()
    var date: Date
    var kind: Kind
    var input: String
    var output: String
    var engine: String

    /// Appends `entry` keeping at most `limit` items, newest first. Pure and unit-tested.
    static func appending(_ entry: HistoryEntry, to list: [HistoryEntry], limit: Int) -> [HistoryEntry] {
        var result = [entry] + list
        if result.count > limit { result.removeLast(result.count - limit) }
        return result
    }
}

/// Persists the last operations as JSON in Application Support. Main-actor: called from the
/// pipelines and read by the menu, both on the main thread.
@MainActor
final class HistoryStore {
    static let shared = HistoryStore()
    static let limit = 50

    private(set) var entries: [HistoryEntry] = []
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = base.appendingPathComponent("BindAll", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("history.json")
        }
        load()
    }

    func record(kind: HistoryEntry.Kind, input: String, output: String, engine: String) {
        let entry = HistoryEntry(date: Date(), kind: kind, input: input, output: output, engine: engine)
        entries = HistoryEntry.appending(entry, to: entries, limit: Self.limit)
        save()
    }

    func clear() {
        entries = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return }
        entries = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
