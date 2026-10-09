import SwiftUI

/// Everything about word autocomplete, starting with its on/off switch.
struct AutocompleteSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var learnedCount = 0
    @State private var showLearned = false

    var body: some View {
        @Bindable var appState = appState
        Form {
            Section {
                HelpToggleRow("Word autocomplete", "Suggests completions for the word you are typing and can predict the next word; press Tab to insert. Works in most apps; skipped in password fields.",
                              isOn: $appState.settings.autocompleteEnabled)
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
                        Toggle("Auto-detect", isOn: $appState.settings.autocompleteLanguages.isAuto)
                        Divider()
                        ForEach(AppLanguages.list, id: \.code) { language in
                            Toggle(language.name, isOn: $appState.settings.autocompleteLanguages.contains(language.code))
                        }
                    }
                    .fixedSize()
                }
            } header: {
                HelpHeader("Suggestions", "How the list looks: how many completions it offers, how they are arranged next to the cursor, and which dictionary languages they come from (or Auto).")
            }

            Section("Behavior") {
                Toggle("Accept with Return too", isOn: $appState.settings.autocompleteAcceptReturn)
                HelpToggleRow("Predict next word", "After a space, suggest the most likely next word, learned from what you have typed before.",
                              isOn: $appState.settings.autocompleteNextWord)
                HelpToggleRow("Learn from what you type", "Remembers the words you use (and which follow which) to rank suggestions and power next-word prediction. Stored locally; words only.",
                              isOn: $appState.settings.autocompleteLearn)
                HelpToggleRow("Rank by context", "Ranks completions using the words before the caret (bundled Russian n-gram data plus what you have typed before), instead of a fixed order.",
                              isOn: $appState.settings.autocompleteContextRanking)
                LabeledContent("Learned words") {
                    HStack {
                        Text(learnedCount, format: .number).foregroundStyle(.secondary)
                        Button("Manage…", action: showLearnedWords).controlSize(.small)
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
        .onAppear(perform: refreshLearnedCount)
        .sheet(isPresented: $showLearned, onDismiss: refreshLearnedCount) {
            LearnedWordsView(languages: appState.settings.autocompleteLanguages)
        }
    }

    private var languagesLabel: String {
        let codes = appState.settings.autocompleteLanguages
        if codes.isEmpty { return "Auto" }
        return codes.map { AppLanguages.name(for: $0) }.joined(separator: ", ")
    }

    private func showLearnedWords() {
        showLearned = true
    }

    private func refreshLearnedCount() {
        learnedCount = AutocompleteLearningStore.shared.wordCount
    }
}
