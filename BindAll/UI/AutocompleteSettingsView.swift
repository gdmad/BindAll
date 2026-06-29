import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Settings for the experimental word autocomplete. The on/off switch also lives on the General tab.
struct AutocompleteSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var learnedCount = 0

    var body: some View {
        Form {
            Section {
                Toggle("Enabled", isOn: $appState.settings.autocompleteEnabled)
            } header: {
                helpHeader("Word autocomplete (experimental)", "As you type, a short list of completions appears near the cursor (arrow keys choose, Tab inserts). It can also predict the next word after a space. Works in most apps; the chip is positioned most precisely in native text fields. Skipped in password fields.")
            }

            Section("Suggestions") {
                Stepper("Suggestions shown: \(appState.settings.autocompleteCount)",
                        value: $appState.settings.autocompleteCount, in: 1...9)
                Picker("Layout", selection: $appState.settings.autocompleteHorizontal) {
                    Text("Column").tag(false)
                    Text("Line").tag(true)
                }
                Stepper("Text size: \(appState.settings.autocompleteFontSize)",
                        value: $appState.settings.autocompleteFontSize, in: 10...20)
                Picker("Language", selection: $appState.settings.autocompleteLanguage) {
                    Text("Auto").tag("auto")
                    ForEach(AppLanguages.list, id: \.code) { Text($0.name).tag($0.code) }
                }
            }

            Section("Behavior") {
                Toggle("Accept with Return too", isOn: $appState.settings.autocompleteAcceptReturn)
                Toggle(isOn: $appState.settings.autocompleteNextWord) {
                    helpHeader("Predict next word", "After a space, suggest the most likely next word based on what you have typed before.")
                }
                Toggle(isOn: $appState.settings.autocompleteLearn) {
                    helpHeader("Learn from what you type", "Remembers the words you use (and which follow which) to rank suggestions and power next-word prediction. Stored locally; words only.")
                }
                LabeledContent("Learned words") {
                    HStack {
                        Text("\(learnedCount)").foregroundStyle(.secondary)
                        Button("Clear") {
                            AutocompleteLearningStore.shared.clear()
                            learnedCount = 0
                        }
                        .controlSize(.small)
                        .disabled(learnedCount == 0)
                    }
                }
            }

            Section {
                Picker("Show in", selection: $appState.settings.autocompleteAppMode) {
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
                    Button("Add app…") { addApp() }
                        .controlSize(.small)
                }
            } header: {
                helpHeader("Apps", "Limit where autocomplete runs. 'Only selected' shows it just in the listed apps; 'All except' disables it there.")
            }
        }
        .formStyle(.grouped)
        .onAppear { learnedCount = AutocompleteLearningStore.shared.wordCount }
    }

    private func appName(_ bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url.deletingPathExtension().lastPathComponent
        }
        return bundleID
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        if !appState.settings.autocompleteApps.contains(bundleID) {
            appState.settings.autocompleteApps.append(bundleID)
        }
    }
}
