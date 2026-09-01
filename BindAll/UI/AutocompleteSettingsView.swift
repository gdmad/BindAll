import SwiftUI

/// Everything about word autocomplete, starting with its on/off switch.
struct AutocompleteSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var learnedCount = 0
    @State private var showLearned = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $appState.settings.autocompleteEnabled) {
                    helpHeader("Word autocomplete", "Suggests completions for the word you are typing and can predict the next word; press Tab to insert. Works in most apps; skipped in password fields.")
                }
            } header: {
                Text("Autocomplete")
            }

            Section {
                Stepper("Suggestions shown: \(appState.settings.autocompleteCount)",
                        value: $appState.settings.autocompleteCount, in: 1...9)
                Picker("Layout", selection: $appState.settings.autocompleteLayout) {
                    ForEach(PopupLayout.allCases, id: \.self) { layout in
                        Text(layout.displayName).tag(layout)
                    }
                }
                LabeledContent("Languages") {
                    Menu(languagesLabel) {
                        Toggle("Auto-detect", isOn: autoBinding)
                        Divider()
                        ForEach(AppLanguages.list, id: \.code) { lang in
                            Toggle(lang.name, isOn: languageBinding(lang.code))
                        }
                    }
                    .fixedSize()
                }
            } header: {
                helpHeader("Suggestions", "How the list looks: how many completions it offers, how they are arranged next to the cursor, and which dictionary languages they come from (or Auto).")
            }

            Section("Behavior") {
                Toggle("Accept with Return too", isOn: $appState.settings.autocompleteAcceptReturn)
                Toggle(isOn: $appState.settings.autocompleteNextWord) {
                    helpHeader("Predict next word", "After a space, suggest the most likely next word, learned from what you have typed before.")
                }
                Toggle(isOn: $appState.settings.autocompleteLearn) {
                    helpHeader("Learn from what you type", "Remembers the words you use (and which follow which) to rank suggestions and power next-word prediction. Stored locally; words only.")
                }
                Toggle(isOn: $appState.settings.autocompleteContextRanking) {
                    helpHeader("Rank by context", "Ranks completions using the words before the caret (bundled Russian n-gram data plus what you have typed before), instead of a fixed order.")
                }
                LabeledContent("Learned words") {
                    HStack {
                        Text("\(learnedCount)").foregroundStyle(.secondary)
                        Button("Manage…") { showLearned = true }.controlSize(.small)
                    }
                }
            }

            AppFilterSection(title: "Apps",
                             help: "Limit where autocomplete runs. 'Only selected' shows it just in the listed apps; 'All except' disables it there.",
                             modeLabel: "Show in",
                             mode: $appState.settings.autocompleteAppMode,
                             apps: $appState.settings.autocompleteApps)
        }
        .formStyle(.grouped)
        .onAppear { learnedCount = AutocompleteLearningStore.shared.wordCount }
        .sheet(isPresented: $showLearned, onDismiss: { learnedCount = AutocompleteLearningStore.shared.wordCount }) {
            LearnedWordsView(languages: appState.settings.autocompleteLanguages)
        }
    }

    // MARK: - Languages

    private var languagesLabel: String {
        let codes = appState.settings.autocompleteLanguages
        if codes.isEmpty { return "Auto" }
        return codes.map { AppLanguages.name(for: $0) }.joined(separator: ", ")
    }

    private var autoBinding: Binding<Bool> {
        Binding(get: { appState.settings.autocompleteLanguages.isEmpty },
                set: { if $0 { appState.settings.autocompleteLanguages = [] } })
    }

    private func languageBinding(_ code: String) -> Binding<Bool> {
        Binding(
            get: { appState.settings.autocompleteLanguages.contains(code) },
            set: { on in
                var list = appState.settings.autocompleteLanguages
                if on { if !list.contains(code) { list.append(code) } }
                else { list.removeAll { $0 == code } }
                appState.settings.autocompleteLanguages = list
            }
        )
    }

}

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
    @State private var confirmRemoveAll = false

    private var filtered: [(word: String, count: Int)] {
        var list = entries
        if onlyTypos {
            list = LearnedWordAudit.suspects(in: list) { !suspects.contains($0) }
        }
        guard !search.isEmpty else { return list }
        return list.filter { $0.word.lowercased().contains(search.lowercased()) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Learned words").font(.headline)
                Spacer()
                Button("Clear All", role: .destructive) {
                    AutocompleteLearningStore.shared.clear()
                    reload()
                }
                .disabled(entries.isEmpty)
                Button("Done") { dismiss() }
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

            typoFilterRow
                .padding(.horizontal)
                .padding(.vertical, 8)

            List {
                if filtered.isEmpty {
                    Text(onlyTypos ? "No suspicious words" : "No words yet").foregroundStyle(.secondary)
                }
                ForEach(filtered, id: \.word) { entry in
                    HStack {
                        if suspects.contains(entry.word) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .help("The dictionary does not know this word")
                        }
                        Text(entry.word)
                        Spacer()
                        Text(entry.count >= LearnedWordAudit.pinnedWeight ? "pinned" : "\(entry.count)")
                            .font(.caption).foregroundStyle(.secondary)
                        Button {
                            AutocompleteLearningStore.shared.remove(word: entry.word)
                            reload()
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(width: 380, height: 440)
        .onAppear {
            reload()
            scan()
        }
        .confirmationDialog("Remove \(filtered.count) word(s)?", isPresented: $confirmRemoveAll) {
            Button("Remove", role: .destructive) { removeAllListed() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They will stop being suggested. Words you pinned by hand are never removed.")
        }
    }

    /// Anything typed twice gets learned, typos included; this is how they are found and dropped.
    private var typoFilterRow: some View {
        HStack {
            Toggle("Only possible typos", isOn: $onlyTypos)
                .toggleStyle(.checkbox)
                .disabled(scanning)
            if scanning {
                ProgressView().controlSize(.small)
            }
            Spacer()
            if onlyTypos, !filtered.isEmpty {
                Button("Remove all listed", role: .destructive) { confirmRemoveAll = true }
                    .controlSize(.small)
            }
        }
    }

    private func reload() {
        entries = AutocompleteLearningStore.shared.entries()
    }

    /// Checks the whole vocabulary against the dictionary off the main thread: NSSpellChecker is slow
    /// enough that doing it inline would stall the sheet on a large vocabulary.
    private func scan() {
        let words = AutocompleteLearningStore.shared.entries()
        let langs = languages
        scanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let unknown = LearnedWordAudit.suspects(in: words) {
                AutocompleteEngine.isKnownWord($0, languages: langs)
            }
            let found = Set(unknown.map(\.word))
            DispatchQueue.main.async {
                suspects = found
                scanning = false
            }
        }
    }

    private func removeAllListed() {
        for entry in filtered {
            AutocompleteLearningStore.shared.remove(word: entry.word)
        }
        reload()
        scan()
    }

    private func addWord() {
        AutocompleteLearningStore.shared.add(custom: newWord)
        newWord = ""
        reload()
        scan()
    }
}
