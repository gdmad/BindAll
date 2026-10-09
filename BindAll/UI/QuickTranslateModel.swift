import Foundation
import Observation
import Translation

/// State and actions of the Quick Translate window. Kept out of the view so the window controller
/// can reach the same copy action from ⌘C (`CopyShortcutMonitor`).
@MainActor @Observable
final class QuickTranslateModel {
    var source: String
    var target: String
    var input = ""
    private(set) var output = ""
    private(set) var isTranslating = false
    private(set) var needsDownload = false
    private(set) var copied = false
    let translation = TranslationCoordinator()

    @ObservationIgnored let onClose: () -> Void
    @ObservationIgnored private let onTranslated: (String, String) -> Void
    @ObservationIgnored private var copiedReset: Task<Void, Never>?

    init(source: String, target: String, onClose: @escaping () -> Void,
         onTranslated: @escaping (String, String) -> Void) {
        self.source = source
        self.target = target
        self.onClose = onClose
        self.onTranslated = onTranslated
    }

    var canCopy: Bool { !output.isEmpty && !needsDownload && !isTranslating }
    var canClear: Bool { !input.isEmpty || !output.isEmpty }

    func swapLanguages() {
        guard source != AppLanguages.autoTag else { return }
        (source, target) = (target, source)
        if !output.isEmpty { translate() }
    }

    /// Copies the whole translation, so nothing has to be selected first.
    func copyOutput() {
        guard canCopy else { return }
        TextInjector.copyToPasteboard(output)
        copied = true
        copiedReset?.cancel()
        copiedReset = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }

    func clear() {
        input = ""
        output = ""
        needsDownload = false
        copied = false
    }

    func translate() {
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
            defer { isTranslating = false }
            guard await TranslationSupport.isInstalledConfirmed(from: src, to: tgt) else {
                needsDownload = true
                let from = AppLanguages.name(for: src.languageCode?.identifier ?? "")
                let to = AppLanguages.name(for: target)
                output = "\(from) -> \(to) is not downloaded yet. Download it once in System Settings, then translation works offline."
                return
            }
            do {
                output = try await translation.translate(text, from: src, to: tgt)
                onTranslated(text, output)
            } catch {
                output = error.localizedDescription
            }
        }
    }
}
