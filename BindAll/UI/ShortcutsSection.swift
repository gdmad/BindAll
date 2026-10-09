import SwiftUI

/// Global shortcut recorders, hosted as a section inside the Actions tab's Form.
struct ShortcutsSection: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        let s = appState.settings
        let keyShortcuts = s.actionKeys.compactMap(\.hotkey)
        Section {
            LabeledContent("Default action") {
                ShortcutRecorder(config: $appState.settings.defaultActionHotkey,
                                 others: [s.translateHotkey, s.screenTranslateHotkey, s.quickTranslateHotkey] + keyShortcuts)
            }
            LabeledContent("Translate selection") {
                ShortcutRecorder(config: $appState.settings.translateHotkey,
                                 others: [s.defaultActionHotkey, s.screenTranslateHotkey, s.quickTranslateHotkey] + keyShortcuts)
            }
            LabeledContent("Translate from screen (OCR)") {
                ShortcutRecorder(config: $appState.settings.screenTranslateHotkey,
                                 others: [s.defaultActionHotkey, s.translateHotkey, s.quickTranslateHotkey] + keyShortcuts)
            }
            LabeledContent("Quick Translate") {
                ShortcutRecorder(config: $appState.settings.quickTranslateHotkey,
                                 others: [s.defaultActionHotkey, s.translateHotkey, s.screenTranslateHotkey] + keyShortcuts)
            }
        } header: {
            HelpHeader("Shortcuts", "Click a field and press the keys. Press the same combo several times for a repeat trigger (shown as e.g. Cmd+C+C). The default Cmd+C also copies, so the selection is captured automatically.")
        }
    }
}
