import Foundation
import Observation

@MainActor @Observable
final class PopupModel {
    let title: String
    let text: String
    let original: String?
    let sourceLanguage: String?
    let targetLanguage: String?
    @ObservationIgnored let onClose: () -> Void
    @ObservationIgnored private var copiedReset: Task<Void, Never>?
    var showOriginal = false
    private(set) var copiedText = false
    private(set) var copiedOriginal = false

    init(title: String, text: String, original: String?, sourceLanguage: String?, targetLanguage: String?,
         onClose: @escaping () -> Void) {
        self.title = title
        self.text = text
        self.original = original
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.onClose = onClose
    }

    /// "Russian → English" when both are known.
    var languagePair: String? {
        guard let sourceLanguage, let targetLanguage else { return nil }
        return "\(sourceLanguage) → \(targetLanguage)"
    }

    func copyText() {
        TextInjector.copyToPasteboard(text)
        copiedText = true
        copiedReset?.cancel()
        copiedReset = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            copiedText = false
        }
    }

    func copyOriginal() {
        guard let original else { return }
        TextInjector.copyToPasteboard(original)
        copiedOriginal = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copiedOriginal = false
        }
    }
}
