import SwiftUI
import Translation

struct QuickTranslateView: View {
    let onClose: () -> Void
    let onTranslated: (String, String) -> Void

    @StateObject private var translation = TranslationCoordinator()
    @State private var source: String
    @State private var target: String
    @State private var input = ""
    @State private var output = ""
    @State private var isTranslating = false
    @State private var needsDownload = false
    @State private var copied = false
    @FocusState private var inputFocused: Bool

    init(initialSource: String, initialTarget: String,
         onClose: @escaping () -> Void,
         onTranslated: @escaping (String, String) -> Void = { _, _ in }) {
        self.onClose = onClose
        self.onTranslated = onTranslated
        _source = State(initialValue: initialSource)
        _target = State(initialValue: initialTarget)
    }

    var body: some View {
        VStack(spacing: 0) {
            QuickTranslateLanguageBar(source: $source, target: $target, swap: swapLanguages)
            Divider()
            QuickTranslateInput(text: $input, focused: $inputFocused, submit: translate)
            Divider()
            QuickTranslateOutput(output: output, needsDownload: needsDownload, copied: copied, copy: copyOutput)
            Divider()
            QuickTranslateFooter(isTranslating: isTranslating)
        }
        .frame(minWidth: 420, minHeight: 380)
        .background(.regularMaterial)
        .ignoresSafeArea()
        // Host the translation session in this visible window so the language-download prompt can
        // appear and be confirmed here (an offscreen host makes it flash and fail).
        .translationTask(translation.configuration) { session in
            await translation.run(with: session)
        }
        .onExitCommand(perform: onClose)
        .onAppear { inputFocused = true }
    }

    private func swapLanguages() {
        guard source != AppLanguages.autoTag else { return }
        (source, target) = (target, source)
        if !output.isEmpty { translate() }
    }

    /// Copies the whole translation, so nothing has to be selected first.
    private func copyOutput() {
        guard !output.isEmpty, !needsDownload else { return }
        TextInjector.copyToPasteboard(output)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    private func translate() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isTranslating = true
        needsDownload = false
        copied = false
        output = ""
        let src: Locale.Language = source == AppLanguages.autoTag
            ? (LanguageDetector.detect(text) ?? Locale.Language(identifier: "en"))
            : Locale.Language(identifier: source)
        let tgt = Locale.Language(identifier: target)
        Task {
            if await TranslationSupport.isInstalledConfirmed(from: src, to: tgt) {
                do {
                    output = try await translation.translate(text, from: src, to: tgt)
                    onTranslated(text, output)
                } catch {
                    output = error.localizedDescription
                }
            } else {
                needsDownload = true
                let from = AppLanguages.name(for: src.languageCode?.identifier ?? "")
                let to = AppLanguages.name(for: target)
                output = "\(from) -> \(to) is not downloaded yet. Download it once in System Settings, then translation works offline."
            }
            isTranslating = false
        }
    }
}
