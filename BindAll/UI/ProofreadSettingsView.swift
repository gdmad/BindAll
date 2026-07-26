import SwiftUI
import AppKit

/// Settings for proofreading, including the LanguageTool connection (LanguageTool serves only this
/// feature). The on/off switch is on General and the shortcut on the Actions tab.
struct ProofreadSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section {
                Stepper("Fixes shown per issue: \(appState.settings.proofreadMaxReplacements)",
                        value: $appState.settings.proofreadMaxReplacements, in: 1...10)
                LabeledContent {
                    Stepper("\(appState.settings.proofreadMinLength) characters",
                            value: $appState.settings.proofreadMinLength, in: 1...100)
                } label: {
                    helpHeader("Skip fields shorter than", "Short fields are usually search boxes, address bars and login forms: checking them would send their contents to the server for nothing. Anything shorter than this is left alone.")
                }
            } header: {
                helpHeader("Proofread", "Shortly after you stop typing, BindAll checks the focused field with LanguageTool and underlines the issues it finds. Click an underlined word to see the fixes: up/down arrows or the mouse choose a fix, Return or a click applies it, Tab and the left/right arrows move to the next problem word, Esc closes the popup. There is no shortcut. Skipped in password fields.\n\nThe whole field is sent one paragraph at a time, so LanguageTool sees enough context to catch grammar; unchanged paragraphs are cached and not sent again.")
            }

            LanguageToolConnectionSection()

            Section {
                Picker("Check in", selection: deferredWrite($appState.settings.proofreadAppMode)) {
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
