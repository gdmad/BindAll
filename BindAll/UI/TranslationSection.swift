import SwiftUI

/// Translation options: the language pair and whether it works offline.
struct TranslationSection: View {
    @Environment(AppState.self) private var appState

    /// Offline status of the currently selected pair: nil = unknown (Auto source).
    @State private var pairInstalled: Bool?

    var body: some View {
        @Bindable var appState = appState
        Section {
            HStack(spacing: 8) {
                Text("Source").foregroundStyle(.secondary)
                LanguagePicker(title: "Source language", selection: $appState.settings.sourceLanguage, includeAuto: true)

                Button("Swap source and target", systemImage: "arrow.left.arrow.right", action: swap)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(appState.settings.sourceLanguage == AppLanguages.autoTag)
                    .help("Swap source and target")

                Text("Target").foregroundStyle(.secondary)
                LanguagePicker(title: "Target language", selection: $appState.settings.targetLanguage, includeAuto: false)
            }
            TranslationStatusRow(autoSource: appState.settings.sourceLanguage == AppLanguages.autoTag,
                                 installed: pairInstalled)
        } header: {
            HelpHeader("Translation", "Source may be Auto Detect or a fixed language. With an explicit source, the pair is bidirectional (text is translated into whichever of source/target it is not). Runs on-device via Apple's Translation framework.")
        }
        .task(id: refreshKey) { await refreshStatus() }
    }

    private var refreshKey: String {
        appState.settings.sourceLanguage + "|" + appState.settings.targetLanguage
    }

    private func swap() {
        let source = appState.settings.sourceLanguage
        guard source != AppLanguages.autoTag else { return }
        appState.settings.sourceLanguage = appState.settings.targetLanguage
        appState.settings.targetLanguage = source
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
