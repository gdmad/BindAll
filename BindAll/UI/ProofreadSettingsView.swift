import SwiftUI

/// Everything about proofreading, starting with its on/off switch and including the LanguageTool
/// connection (LanguageTool serves only this feature). There is no shortcut: checking runs on its
/// own after a pause in typing.
struct ProofreadSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $appState.settings.correctEnabled) {
                    helpHeader("Enable Proofread", "Checks the text field you are typing in with a LanguageTool server shortly after you pause, and underlines every issue in place. Click an underlined word to see the fixes. The public server sends text to languagetool.org; use a self-hosted server for full privacy.")
                }
            } header: {
                Text("Proofread (LanguageTool)")
            }

            Section {
                Stepper("Fixes shown per issue: \(appState.settings.proofreadMaxReplacements)",
                        value: $appState.settings.proofreadMaxReplacements, in: 1...10)
                Picker("Layout", selection: $appState.settings.proofreadLayout) {
                    ForEach(PopupLayout.allCases, id: \.self) { layout in
                        Text(layout.displayName).tag(layout)
                    }
                }
                LabeledContent("Language") {
                    Picker("", selection: $appState.settings.languageToolLanguage) {
                        Text("Auto Detect").tag(AppLanguages.autoTag)
                        ForEach(AppLanguages.list, id: \.code) { Text($0.name).tag($0.code) }
                    }
                    .labelsHidden().fixedSize()
                }
                LabeledContent {
                    // Value first, arrows after it: a Stepper's own label goes to the right of the
                    // control, which reads backwards inside a right-aligned row.
                    HStack(spacing: 6) {
                        Text("\(appState.settings.proofreadMinLength) characters")
                        Stepper("", value: $appState.settings.proofreadMinLength, in: 1...100)
                            .labelsHidden()
                    }
                } label: {
                    helpHeader("Skip fields shorter than", "Short fields are usually search boxes, address bars and login forms: checking them would send their contents to the server for nothing. Anything shorter than this is left alone.")
                }
            } header: {
                helpHeader("Checking", "Click an underlined word to see the fixes: up/down arrows or the mouse choose a fix, Return or a click applies it, Tab and the left/right arrows move to the next problem word, Esc closes the popup. Skipped in password fields.\n\nThe whole field is sent one paragraph at a time, so LanguageTool sees enough context to catch grammar; unchanged paragraphs are cached and not sent again.")
            }

            LanguageToolConnectionSection()

            AppFilterSection(title: "Apps",
                             help: "Limit where proofreading runs. 'Only selected' checks just the listed apps; 'All except' leaves them alone.",
                             modeLabel: "Check in",
                             mode: $appState.settings.proofreadAppMode,
                             apps: $appState.settings.proofreadApps)
        }
        .formStyle(.grouped)
    }
}
