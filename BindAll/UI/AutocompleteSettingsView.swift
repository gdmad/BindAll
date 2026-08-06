import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Settings for word autocomplete. The on/off switch lives on the General tab.
struct AutocompleteSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var learnedCount = 0
    @State private var showLearned = false

    var body: some View {
        Form {
            Section {
                Stepper("Suggestions shown: \(appState.settings.autocompleteCount)",
                        value: $appState.settings.autocompleteCount, in: 1...9)
                Picker("Layout", selection: deferredWrite($appState.settings.autocompleteHorizontal)) {
                    Text("Column").tag(false)
                    Text("Line").tag(true)
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
                helpHeader("Word autocomplete", "As you type, a list of completions appears near the cursor (arrow keys choose, Tab inserts). Pick one or more dictionary languages, or Auto. Skipped in password fields.")
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

            Section {
                Picker("Show in", selection: deferredWrite($appState.settings.autocompleteAppMode)) {
                    Text("All apps").tag("all")
                    Text("Only selected apps").tag("allow")
                    Text("All except selected").tag("deny")
                }
                if appState.settings.autocompleteAppMode != "all" {
                    ForEach(appState.settings.autocompleteApps, id: \.self) { bundleID in
                        HStack {
                            Text(appName(bundleID))
                            Spacer()
                            Button {
                                appState.settings.autocompleteApps.removeAll { $0 == bundleID }
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Menu("Add app…") {
                        Menu("Running apps") {
                            ForEach(runningApps(), id: \.id) { app in
                                Button(app.name) { addBundle(app.id) }
                            }
                        }
                        Button("Choose from disk…") { addAppFromDisk() }
                    }
                    .controlSize(.small)
                    .fixedSize()
                }
            } header: {
                helpHeader("Apps", "Limit where autocomplete runs. 'Only selected' shows it just in the listed apps; 'All except' disables it there.")
            }
        }
        .formStyle(.grouped)
        .onAppear { learnedCount = AutocompleteLearningStore.shared.wordCount }
        .sheet(isPresented: $showLearned, onDismiss: { learnedCount = AutocompleteLearningStore.shared.wordCount }) {
            LearnedWordsView()
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

    // MARK: - Apps

    private func appName(_ bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url.deletingPathExtension().lastPathComponent
        }
        return bundleID
    }

    private func addBundle(_ bundleID: String) {
        if !appState.settings.autocompleteApps.contains(bundleID) {
            appState.settings.autocompleteApps.append(bundleID)
        }
    }

    /// Currently-running regular apps (includes Safari/Chrome web apps while they run), sorted by name.
    private func runningApps() -> [(id: String, name: String)] {
        let mine = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        var apps: [(id: String, name: String)] = []
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier, id != mine, !seen.contains(id) else { continue }
            seen.insert(id)
            apps.append((id: id, name: app.localizedName ?? id))
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func addAppFromDisk() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        addBundle(bundleID)
    }
}

/// View, add, and remove learned words.
struct LearnedWordsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [(word: String, count: Int)] = []
    @State private var search = ""
    @State private var newWord = ""

    private var filtered: [(word: String, count: Int)] {
        guard !search.isEmpty else { return entries }
        return entries.filter { $0.word.lowercased().contains(search.lowercased()) }
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
                .padding(.bottom, 8)

            List {
                if filtered.isEmpty {
                    Text("No words yet").foregroundStyle(.secondary)
                }
                ForEach(filtered, id: \.word) { entry in
                    HStack {
                        Text(entry.word)
                        Spacer()
                        Text(entry.count >= 1_000_000 ? "pinned" : "\(entry.count)")
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
        .onAppear(perform: reload)
    }

    private func reload() {
        entries = AutocompleteLearningStore.shared.entries()
    }

    private func addWord() {
        AutocompleteLearningStore.shared.add(custom: newWord)
        newWord = ""
        reload()
    }
}
