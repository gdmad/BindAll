import Foundation
import Observation

/// Root observable model. Owns settings persistence and exposes Keychain-backed API keys.
@MainActor @Observable
final class AppState {
    @ObservationIgnored private static let settingsKey = "BindAll.settings.v1"

    var settings: Settings {
        didSet { persist() }
    }

    /// Live Accessibility permission status (updated by the coordinator).
    var accessibilityGranted: Bool = false
    /// Whether the global hotkey tap is actually installed and enabled right now (updated by the
    /// coordinator) -- distinct from `accessibilityGranted`: the permission can show as granted in
    /// System Settings while the tap itself is stale or was never (re)installed. Surfacing this
    /// separately in Status is what makes that state visible instead of silently doing nothing.
    var hotkeysActive: Bool = false
    /// Human-readable Apple Intelligence availability status.
    var appleEngineStatus: String = "Unknown"
    /// True while an action/translation is running (drives the menu-bar icon).
    var isProcessing: Bool = false
    /// True while the user is recording a shortcut in Settings (pauses global hotkeys).
    var isRecordingShortcut: Bool = false

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

    /// Bumped whenever a key or token in the Keychain changes. The Keychain is out of observation's
    /// sight, so this is what views showing a key, and the coordinator that rebuilds engines from
    /// them, observe instead.
    private(set) var keychainRevision = 0

    func apiKey(for kind: ProviderKind) -> String {
        _ = keychainRevision
        return KeychainStore.get(account: kind.keychainAccount) ?? ""
    }

    func setAPIKey(_ value: String, for kind: ProviderKind) {
        KeychainStore.set(value, account: kind.keychainAccount)
        keychainRevision += 1
    }

    // MARK: - LanguageTool token (Keychain)

    private static let languageToolAccount = "languagetool.apikey"

    func languageToolToken() -> String {
        _ = keychainRevision
        return KeychainStore.get(account: Self.languageToolAccount) ?? ""
    }

    /// Stores the token. `reconfigure` bumps `keychainRevision` so the hotkey coordinator rebuilds
    /// the LanguageTool engine with it. Pass `false` while the user is still typing it, and once
    /// more with `true` when the field is done. (Re-assigning `settings` to itself used to do this;
    /// an observable property does not notify when assigned an equal value.)
    func setLanguageToolToken(_ value: String, reconfigure: Bool = true) {
        KeychainStore.set(value, account: Self.languageToolAccount)
        if reconfigure { keychainRevision += 1 }
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
