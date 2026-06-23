import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            ActionsSettingsView()
                .tabItem { Label("Actions", systemImage: "text.badge.checkmark") }
            ProvidersSettingsView()
                .tabItem { Label("Providers", systemImage: "cloud") }
            TranslationSettingsView()
                .tabItem { Label("Translation", systemImage: "globe") }
            HotkeysSettingsView()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .padding(.top, 8)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 478, idealHeight: 558)
    }
}

// MARK: - Help hint

/// A small question-mark icon that reveals `text` on hover (tooltip) and on click (popover).
struct HelpHint: View {
    let text: String
    @State private var showPopover = false
    init(_ text: String) { self.text = text }
    var body: some View {
        Button { showPopover.toggle() } label: {
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Help")
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 280)
                .padding(12)
        }
    }
}

/// A section header with a trailing help icon.
func helpHeader(_ title: String, _ help: String) -> some View {
    HStack(spacing: 4) {
        Text(title)
        HelpHint(help)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(
                    get: { LoginItemManager.isEnabled },
                    set: { LoginItemManager.apply($0) }
                ))
            }

            Section {
                Picker("Engine for text actions", selection: $appState.settings.defaultEngine) {
                    ForEach(ProviderKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
            } header: {
                helpHeader("Engine", "Used for the default action and custom prompts. Translation always runs on-device via Apple's Translation framework.")
            }

            Section {
                Toggle(isOn: $appState.settings.correctEnabled) {
                    helpHeader("Enable Correct", "Adds a separate shortcut that fixes grammar and spelling in the selection with a LanguageTool server. Set its shortcut in Shortcuts and the server in Providers. The public server sends text to languagetool.org; use a self-hosted server for full privacy.")
                }
            } header: {
                Text("Correct (LanguageTool)")
            }

            Section("Output") {
                Toggle(isOn: $appState.settings.restoreClipboard) {
                    helpHeader("Restore clipboard after replacing", "When replacing the selection, BindAll puts the result on the clipboard and pastes it. With this on, your previous clipboard contents are restored a moment after pasting, so the tool does not overwrite what you had copied. Off: the result stays on the clipboard.")
                }
                Toggle(isOn: $appState.settings.maskAISlop) {
                    helpHeader("Mask AI Slop", "Normalizes typical 'AI' typography in results: em/en dashes become '-', smart quotes and apostrophes become straight ones, and emoji and unusual unicode are stripped.")
                }
                Toggle(isOn: $appState.settings.historyEnabled) {
                    helpHeader("Keep history", "Stores the last 50 results locally (menu bar > History) so a closed popup or overwritten paste can be recovered. Stored on this Mac only; never includes API keys.")
                }
            }

            Section {
                LabeledContent("Accessibility") {
                    if appState.accessibilityGranted {
                        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Grant Access…") { AccessibilityPermission.openSystemSettings() }
                    }
                }
                LabeledContent("Apple on-device model", value: appState.appleEngineStatus)
            } header: {
                helpHeader("Status", "Live status. Accessibility is required for the global shortcuts and for pasting results back into the active app. Apple on-device model shows whether Apple Intelligence is available for the on-device engine.")
            }

            Section("About") {
                LabeledContent("Version", value: UpdateChecker.currentVersion)
                LabeledContent("Source code") {
                    Link("GitHub", destination: UpdateChecker.repositoryURL)
                }
                Button("Check for Updates…") { UpdateChecker.checkForUpdates() }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Actions

struct ActionsSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section {
                TextEditor(text: $appState.settings.defaultPrompt)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(height: 90)
                    .darkField()
                Button("Restore default prompt") {
                    appState.settings.defaultPrompt = Settings().defaultPrompt
                }
                .controlSize(.small)
            } header: {
                helpHeader("Default action", "With no separator, the selected text is processed with this prompt (spelling, grammar and punctuation by default).")
            }

            Section {
                LabeledContent("Separator") {
                    TextField("", text: $appState.settings.separator)
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .darkField()
                }
            } header: {
                helpHeader("Separator", "Text after the last separator is treated as the instruction. Example: \"make this formal -- tr\" runs the tr action on the text before the separator.")
            }

            Section {
                ActionKeysSettingsView()
            } header: {
                helpHeader("Action keys", "Short keys you type after the separator. The instruction is sent to the AI for the text before the separator. A key can also get its own global shortcut (Record Shortcut in the expanded row): pressing it runs the instruction on the current selection directly, no separator needed.")
            }
        }
        .formStyle(.grouped)
        .clearFocusOnAppear()
    }
}

// MARK: - Translation

struct TranslationSettingsView: View {
    @EnvironmentObject var appState: AppState

    /// Offline status of the currently selected pair: nil = unknown (Auto source).
    @State private var pairInstalled: Bool?

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    Text("Source").foregroundStyle(.secondary)
                    languagePicker(selection: $appState.settings.sourceLanguage, includeAuto: true)

                    Button { swap() } label: { Image(systemName: "arrow.left.arrow.right") }
                        .buttonStyle(.borderless)
                        .disabled(appState.settings.sourceLanguage == AppLanguages.autoTag)
                        .help("Swap source and target")

                    Text("Target").foregroundStyle(.secondary)
                    languagePicker(selection: $appState.settings.targetLanguage, includeAuto: false)
                }
                statusRow
            } header: {
                helpHeader("Translation", "Source may be Auto Detect or a fixed language. With an explicit source, the pair is bidirectional (text is translated into whichever of source/target it is not). Runs on-device via Apple's Translation framework.")
            }
        }
        .formStyle(.grouped)
        .task(id: refreshKey) { await refreshStatus() }
    }

    @ViewBuilder
    private var statusRow: some View {
        if appState.settings.sourceLanguage == AppLanguages.autoTag {
            Label("Source is auto-detected; the pack downloads on first use if needed.",
                  systemImage: "wand.and.stars")
                .font(.caption).foregroundStyle(.secondary)
        } else if let installed = pairInstalled {
            if installed {
                Label("Offline ready", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            } else {
                HStack {
                    Label("Will download on first use", systemImage: "arrow.down.circle")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Language Settings") { TranslationSupport.openLanguageSettings() }
                        .controlSize(.small)
                }
            }
        }
    }

    private var refreshKey: String {
        appState.settings.sourceLanguage + "|" + appState.settings.targetLanguage
    }

    @ViewBuilder
    private func languagePicker(selection: Binding<String>, includeAuto: Bool) -> some View {
        Picker("", selection: selection) {
            if includeAuto { Text("Auto Detect").tag(AppLanguages.autoTag) }
            ForEach(AppLanguages.list, id: \.code) { lang in
                Text(lang.name).tag(lang.code)
            }
        }
        .labelsHidden()
        .fixedSize()
    }

    private func swap() {
        let s = appState.settings.sourceLanguage
        guard s != AppLanguages.autoTag else { return }
        appState.settings.sourceLanguage = appState.settings.targetLanguage
        appState.settings.targetLanguage = s
    }

    private func refreshStatus() async {
        let source = appState.settings.sourceLanguage
        let target = appState.settings.targetLanguage
        guard source != AppLanguages.autoTag, source != target else {
            pairInstalled = source == target ? true : nil
            return
        }
        let a = Locale.Language(identifier: source)
        let b = Locale.Language(identifier: target)
        let forward = await TranslationSupport.isInstalled(from: a, to: b)
        let backward = await TranslationSupport.isInstalled(from: b, to: a)
        pairInstalled = forward || backward
    }
}

// MARK: - Hotkeys

struct HotkeysSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        let s = appState.settings
        let keyShortcuts = s.actionKeys.compactMap(\.hotkey)
        let correct: [HotkeyConfig] = s.correctEnabled ? [s.correctHotkey] : []
        Form {
            Section {
                LabeledContent("Default action") {
                    ShortcutRecorder(config: $appState.settings.defaultActionHotkey,
                                     others: [s.translateHotkey, s.screenTranslateHotkey, s.quickTranslateHotkey] + correct + keyShortcuts)
                }
                LabeledContent("Translate selection") {
                    ShortcutRecorder(config: $appState.settings.translateHotkey,
                                     others: [s.defaultActionHotkey, s.screenTranslateHotkey, s.quickTranslateHotkey] + correct + keyShortcuts)
                }
                LabeledContent("Translate from screen (OCR)") {
                    ShortcutRecorder(config: $appState.settings.screenTranslateHotkey,
                                     others: [s.defaultActionHotkey, s.translateHotkey, s.quickTranslateHotkey] + correct + keyShortcuts)
                }
                LabeledContent("Quick Translate") {
                    ShortcutRecorder(config: $appState.settings.quickTranslateHotkey,
                                     others: [s.defaultActionHotkey, s.translateHotkey, s.screenTranslateHotkey] + correct + keyShortcuts)
                }
                if s.correctEnabled {
                    LabeledContent("Correct (LanguageTool)") {
                        ShortcutRecorder(config: $appState.settings.correctHotkey,
                                         others: [s.defaultActionHotkey, s.translateHotkey, s.screenTranslateHotkey, s.quickTranslateHotkey] + keyShortcuts)
                    }
                }
            } header: {
                helpHeader("Shortcut", "Click a field and press the keys. Press the same combo several times for a repeat trigger (shown as e.g. Cmd+C+C). The default Cmd+C also copies, so the selection is captured automatically.")
            }
        }
        .formStyle(.grouped)
    }
}
