import SwiftUI

/// View, add, and remove learned words -- including the ones that are really typos.
struct LearnedWordsView: View {
    /// Dictionary languages to check against; empty means the auto-detected one.
    let languages: [String]

    @Environment(\.dismiss) private var dismiss
    @State private var entries: [(word: String, count: Int)] = []
    @State private var search = ""
    @State private var newWord = ""
    /// Words the dictionary does not know. Filled by a background pass over the whole vocabulary.
    @State private var suspects: Set<String> = []
    @State private var scanning = false
    @State private var onlyTypos = false
    /// Bumped whenever the vocabulary changes, to re-run the dictionary pass.
    @State private var scanGeneration = 0

    private var filtered: [(word: String, count: Int)] {
        var list = entries
        if onlyTypos {
            list = LearnedWordAudit.suspects(in: list) { !suspects.contains($0) }
        }
        guard !search.isEmpty else { return list }
        return list.filter { $0.word.localizedStandardContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Learned words").font(.headline)
                Spacer()
                Button("Clear All", role: .destructive, action: clearAll)
                    .disabled(entries.isEmpty)
                Button("Done", action: close)
            }
            .padding()

            Divider()

            HStack {
                TextField("Add a word (pinned to the top)", text: $newWord)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addWord)
                Button("Add", action: addWord)
                    .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)

            TypoFilterRow(onlyTypos: $onlyTypos, scanning: scanning,
                          listedCount: filtered.count, removeListed: removeAllListed)
                .padding(.horizontal)
                .padding(.vertical, 8)

            List {
                if filtered.isEmpty {
                    Text(onlyTypos ? "No suspicious words" : "No words yet").foregroundStyle(.secondary)
                }
                ForEach(filtered, id: \.word) { entry in
                    LearnedWordRow(word: entry.word, count: entry.count,
                                   isSuspect: suspects.contains(entry.word), remove: remove)
                }
            }
        }
        .frame(width: 380, height: 440)
        .onAppear(perform: reload)
        .task(id: scanGeneration) { await scan() }
    }

    private func reload() {
        entries = AutocompleteLearningStore.shared.entries()
    }

    /// Re-reads the vocabulary and re-runs the dictionary pass.
    private func changed() {
        reload()
        scanGeneration += 1
    }

    /// Checks the whole vocabulary against the dictionary off the main actor: NSSpellChecker is slow
    /// enough that doing it inline would stall the sheet on a large vocabulary.
    private func scan() async {
        scanning = true
        let found = await Self.unknownWords(in: AutocompleteLearningStore.shared.entries(), languages: languages)
        guard !Task.isCancelled else { return }
        suspects = found
        scanning = false
    }

    @concurrent
    private static func unknownWords(in words: [(word: String, count: Int)], languages: [String]) async -> Set<String> {
        let unknown = LearnedWordAudit.suspects(in: words) {
            AutocompleteEngine.isKnownWord($0, languages: languages)
        }
        return Set(unknown.map(\.word))
    }

    private func clearAll() {
        AutocompleteLearningStore.shared.clear()
        changed()
    }

    private func close() {
        dismiss()
    }

    private func remove(_ word: String) {
        AutocompleteLearningStore.shared.remove(word: word)
        changed()
    }

    private func removeAllListed() {
        for entry in filtered {
            AutocompleteLearningStore.shared.remove(word: entry.word)
        }
        changed()
    }

    private func addWord() {
        AutocompleteLearningStore.shared.add(custom: newWord)
        newWord = ""
        changed()
    }
}
