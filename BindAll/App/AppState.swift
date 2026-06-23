import Foundation
import Combine

/// Root observable model. Owns settings persistence and exposes Keychain-backed API keys.
@MainActor
final class AppState: ObservableObject {
    private static let settingsKey = "BindAll.settings.v1"

    @Published var settings: Settings {
        didSet { persist() }
    }

    /// Live Accessibility permission status (updated by the coordinator).
    @Published var accessibilityGranted: Bool = false
    /// Human-readable Apple Intelligence availability status.
    @Published var appleEngineStatus: String = "Unknown"
    /// True while an action/translation is running (drives the menu-bar icon).
    @Published var isProcessing: Bool = false
    /// True while the user is recording a shortcut in Settings (pauses global hotkeys).
    @Published var isRecordingShortcut: Bool = false

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let decoded = try? JSONDecoder().decode(Settings.self, from: data) {
            settings = decoded
        } else {
            settings = Settings()
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: Self.settingsKey)
    }

    // MARK: - API keys (Keychain)

    func apiKey(for kind: ProviderKind) -> String {
        KeychainStore.get(account: kind.keychainAccount) ?? ""
    }

    func setAPIKey(_ value: String, for kind: ProviderKind) {
        KeychainStore.set(value, account: kind.keychainAccount)
        objectWillChange.send()
    }

    // MARK: - LanguageTool token (Keychain)

    private static let languageToolAccount = "languagetool.apikey"

    func languageToolToken() -> String {
        KeychainStore.get(account: Self.languageToolAccount) ?? ""
    }

    func setLanguageToolToken(_ value: String) {
        KeychainStore.set(value, account: Self.languageToolAccount)
        objectWillChange.send()
    }

    // MARK: - Provider config helpers

    func binding(for kind: ProviderKind) -> ProviderConfig {
        settings.provider(kind)
    }

    func updateProvider(_ config: ProviderConfig) {
        if let idx = settings.providers.firstIndex(where: { $0.kind == config.kind }) {
            settings.providers[idx] = config
        } else {
            settings.providers.append(config)
        }
    }
}
