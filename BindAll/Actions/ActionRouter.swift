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
}
