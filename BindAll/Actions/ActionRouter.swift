import Foundation

/// Builds an `AIEngine` for a given provider from the current settings + Keychain.
@MainActor
enum EngineFactory {
    static func make(kind: ProviderKind, appState: AppState) -> AIEngine {
        switch kind {
        case .apple:
            return AppleFoundationEngine()
        case .deepseek, .openrouter, .openai, .ollama:
            let config = appState.settings.provider(kind)
            return OpenAICompatibleEngine(
                baseURL: config.effectiveBaseURL,
                apiKey: appState.apiKey(for: kind),
                model: config.model,
                requiresAPIKey: kind.requiresAPIKey
            )
        }
    }

    /// Builds the LanguageTool client used by the "Correct" action from settings + Keychain.
    static func makeLanguageTool(appState: AppState) -> LanguageToolEngine {
        let s = appState.settings
        return LanguageToolEngine(
            baseURL: s.languageToolBaseURL,
            username: s.languageToolUsername,
            apiKey: appState.languageToolToken(),
            language: s.languageToolLanguage
        )
    }
}
