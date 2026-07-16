import SwiftUI
import AppKit

/// Settings for proofreading. The on/off switch is on General, the shortcut in Shortcuts, and the
/// server and language in Providers: this is the Correct action reworked, not a second feature, so it
/// shares that configuration rather than duplicating it.
struct ProofreadSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $appState.settings.proofreadAutoOnSelection) {
                    helpHeader("Show fixes when I select a word", "Select a word with a problem and the list of fixes appears under it, with no shortcut. Long selections are ignored, so selecting a paragraph to copy it stays quiet.")
                }
                Stepper("Check text longer than: \(appState.settings.proofreadMinLength) characters",
                        value: $appState.settings.proofreadMinLength, in: 1...100)
            } header: {
                helpHeader("Proofread", "Press the Proofread shortcut in any text field: BindAll checks the whole field with LanguageTool, selects the first problem and shows the fixes under it. Arrows choose, Return applies, Tab skips to the next one, Esc exits. Skipped in password fields.")
            }

            Section {
                LabeledContent("Server") {
                    Text(serverLabel).foregroundStyle(.secondary)
                }
                LabeledContent("Language") {
                    Text(languageLabel).foregroundStyle(.secondary)
                }
                Text("Set both on the Providers tab. The whole field is sent, one paragraph at a time, so LanguageTool sees enough context to catch grammar rather than just unknown words. Unchanged paragraphs are cached and not sent again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("LanguageTool")
            }

            Section {
                Picker("Check in", selection: $appState.settings.proofreadAppMode) {
                    Text("All apps").tag("all")
                    Text("Only selected apps").tag("allow")
                    Text("All except selected").tag("deny")
                }
                if appState.settings.proofreadAppMode != "all" {
                    ForEach(appState.settings.proofreadApps, id: \.self) { bundleID in
                        HStack {
                            Text(appName(bundleID))
                            Spacer()
                            Button {
                                appState.settings.proofreadApps.removeAll { $0 == bundleID }
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Menu("Add app…") {
                        ForEach(runningApps(), id: \.id) { app in
                            Button(app.name) { addBundle(app.id) }
                        }
                    }
                    .fixedSize()
                }
            } header: {
                Text("Apps")
            }
        }
        .formStyle(.grouped)
    }

    private var serverLabel: String {
        let url = appState.settings.languageToolBaseURL.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return "Not set" }
        let host = URL(string: url)?.host ?? url
        return host == "api.languagetool.org" ? "\(host) (public)" : host
    }

    private var languageLabel: String {
        let code = appState.settings.languageToolLanguage
        return code == "auto" ? "Auto-detect" : AppLanguages.name(for: code)
    }

    private func appName(_ bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url.deletingPathExtension().lastPathComponent
        }
        return bundleID
    }

    private func addBundle(_ bundleID: String) {
        if !appState.settings.proofreadApps.contains(bundleID) {
            appState.settings.proofreadApps.append(bundleID)
        }
    }

    private func runningApps() -> [(id: String, name: String)] {
        let mine = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        var apps: [(id: String, name: String)] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier, id != mine, !seen.contains(id) else { continue }
            seen.insert(id)
            apps.append((id: id, name: app.localizedName ?? id))
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
