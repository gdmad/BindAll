import SwiftUI

struct ActionsSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            ShortcutsSection()

            Section {
                // A TextEditor, not a vertical TextField: the prompt is multi-paragraph text where
                // Return must insert a newline.
                TextEditor(text: deferredWrite($appState.settings.defaultPrompt))
                    .scrollContentBackground(.hidden)
                    .frame(height: 90)
                    .darkField()
                Button("Restore default prompt", action: restoreDefaultPrompt)
                    .controlSize(.small)
            } header: {
                HelpHeader("Default action", "With no separator, the selected text is processed with this prompt (spelling, grammar and punctuation by default).")
            }

            Section {
                LabeledContent("Separator") {
                    TextField("Separator", text: deferredWrite($appState.settings.separator))
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .darkField()
                }
            } header: {
                HelpHeader("Separator", "Text after the last separator is treated as the instruction. Example: \"make this formal -- tr\" runs the tr action on the text before the separator.")
            }

            Section {
                ActionKeysSettingsView()
            } header: {
                HelpHeader("Action keys", "Short keys you type after the separator. The instruction is sent to the AI for the text before the separator. A key can also get its own global shortcut (Record Shortcut in the expanded row): pressing it runs the instruction on the current selection directly, no separator needed.")
            }
        }
        .formStyle(.grouped)
        .clearFocusOnAppear()
    }

    private func restoreDefaultPrompt() {
        appState.settings.defaultPrompt = Settings().defaultPrompt
    }
}
