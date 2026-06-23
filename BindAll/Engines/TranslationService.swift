import SwiftUI
import AppKit
import Translation
import NaturalLanguage

/// Helpers around language-pack availability for on-device translation.
enum TranslationSupport {
    /// True only if the offline assets for the pair are already installed (no download needed).
    static func isInstalled(from source: Locale.Language, to target: Locale.Language) async -> Bool {
        await LanguageAvailability().status(from: source, to: target) == .installed
    }

    /// Opens System Settings at Language & Region, where Translation Languages are managed.
    @MainActor static func openLanguageSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Detects the dominant language of a piece of text.
enum LanguageDetector {
    /// Returns a `Locale.Language` if detection is confident enough, otherwise nil (let Translation auto-detect).
    static func detect(_ text: String, minimumConfidence: Double = 0.5) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let dominant = recognizer.dominantLanguage else { return nil }
        let hypotheses = recognizer.languageHypotheses(withMaximum: 1)
        let confidence = hypotheses[dominant] ?? 0
        // Short inputs (a word or two) give NL low confidence even when the language is obvious, so
        // the threshold is relaxed by length; longer inputs keep the stricter bar.
        let count = text.trimmingCharacters(in: .whitespacesAndNewlines).count
        let effectiveMin = count < 25 ? 0.15 : minimumConfidence
        guard confidence >= effectiveMin else { return nil }
        return Locale.Language(identifier: dominant.rawValue)
    }
}

/// Bridges the SwiftUI-only `Translation` API into an async call.
///
/// A hidden `TranslationHostView` owns the `.translationTask`; this coordinator drives it by
/// publishing a configuration and resuming a continuation once the session produces a result.
@MainActor
final class TranslationCoordinator: ObservableObject {
    @Published var configuration: TranslationSession.Configuration?

    private struct Pending {
        let text: String
        let continuation: CheckedContinuation<String, Error>
    }
    private var pending: [Pending] = []
    private var currentSource: Locale.Language?
    private var currentTarget: Locale.Language?

    func translate(_ text: String, from source: Locale.Language?, to target: Locale.Language) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            pending.append(Pending(text: text, continuation: continuation))
            if configuration == nil || currentSource != source || currentTarget != target {
                // First request, or the language pair changed: install a fresh configuration.
                currentSource = source
                currentTarget = target
                configuration = TranslationSession.Configuration(source: source, target: target)
            } else {
                // Same language pair as before: invalidate() so `.translationTask` runs again.
                // (Re-assigning an equal configuration would NOT re-trigger it.)
                configuration?.invalidate()
            }
        }
    }

    /// Called by the host view whenever a session becomes available.
    func run(with session: TranslationSession) async {
        let items = pending
        pending.removeAll()
        for item in items {
            do {
                let response = try await session.translate(item.text)
                item.continuation.resume(returning: response.targetText)
            } catch {
                item.continuation.resume(throwing: error)
            }
        }
    }
}

/// Invisible view that hosts the Translation session. Kept alive in an offscreen window.
struct TranslationHostView: View {
    @ObservedObject var coordinator: TranslationCoordinator

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(coordinator.configuration) { session in
                await coordinator.run(with: session)
            }
    }
}
