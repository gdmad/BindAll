import Foundation

// MARK: - Providers

enum ProviderKind: String, Codable, CaseIterable, Identifiable {
    case apple
    case deepseek
    case openrouter
    case openai
    case ollama

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apple: return "Apple On-Device"
        case .deepseek: return "DeepSeek"
        case .openrouter: return "OpenRouter"
        case .openai: return "OpenAI"
        case .ollama: return "Ollama (local)"
        }
    }

    /// Whether this provider needs an API key stored in the Keychain.
    var requiresAPIKey: Bool {
        switch self {
        case .apple, .ollama: return false
        case .deepseek, .openrouter, .openai: return true
        }
    }

    /// Default OpenAI-compatible base URL (nil for the Apple engine).
    var defaultBaseURL: String? {
        switch self {
        case .apple: return nil
        case .deepseek: return "https://api.deepseek.com"
        case .openrouter: return "https://openrouter.ai/api/v1"
        case .openai: return "https://api.openai.com/v1"
        case .ollama: return "http://localhost:11434/v1"
        }
    }

    var defaultModel: String {
        switch self {
        case .apple: return "system"
        case .deepseek: return "deepseek-chat"
        case .openrouter: return "openai/gpt-4o-mini"
        case .openai: return "gpt-4o-mini"
        case .ollama: return "llama3.1"
        }
    }

    /// The Keychain account used to store this provider's API key.
    var keychainAccount: String { "provider.\(rawValue).apikey" }
}

struct ProviderConfig: Codable, Identifiable, Hashable {
    var kind: ProviderKind
    var baseURLOverride: String?
    var model: String

    var id: ProviderKind { kind }

    var effectiveBaseURL: String {
        baseURLOverride?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? (kind.defaultBaseURL ?? "")
    }

    static func makeDefault(_ kind: ProviderKind) -> ProviderConfig {
        ProviderConfig(kind: kind, baseURLOverride: nil, model: kind.defaultModel)
    }
}

// MARK: - Hotkeys

struct HotkeyModifiers: Codable, Hashable {
    var command: Bool = true
    var option: Bool = false
    var control: Bool = false
    var shift: Bool = false

    var isEmpty: Bool { !command && !option && !control && !shift }
}

struct HotkeyConfig: Codable, Hashable {
    /// Virtual key code (kVK_*). Default 8 == "C".
    var keyCode: UInt16
    var modifiers: HotkeyModifiers
    /// Number of presses required to trigger. The detection window is a single app-wide constant
    /// (`HotkeyMonitor.burstWindow`), not a stored setting.
    var repeatCount: Int

    static let defaultAction = HotkeyConfig(keyCode: 8, modifiers: HotkeyModifiers(command: true), repeatCount: 2)
    static let translate = HotkeyConfig(keyCode: 8, modifiers: HotkeyModifiers(command: true), repeatCount: 3)
    static let screenTranslate = HotkeyConfig(keyCode: 14, modifiers: HotkeyModifiers(command: true), repeatCount: 1)
    static let quickTranslate = HotkeyConfig(keyCode: 14, modifiers: HotkeyModifiers(command: true, shift: true), repeatCount: 1)
    /// Correct (LanguageTool): Cmd+Shift+C by default.
    static let correct = HotkeyConfig(keyCode: 8, modifiers: HotkeyModifiers(command: true, shift: true), repeatCount: 1)
}

// MARK: - Root settings

struct Settings: Codable, Equatable {
    var enabled: Bool = true

    // Engine selection
    var defaultEngine: ProviderKind = .apple

    // Default action parsing
    var separator: String = "--"
    var defaultPrompt: String =
        "Fix spelling, grammar and punctuation. Keep the same language and formatting. Return only the corrected text."
    var actionKeys: [ActionKey] = ActionKey.defaults
    var restoreClipboard: Bool = false

    // Text post-processing
    var maskAISlop: Bool = false

    // Experimental: suggest a completion for the word being typed, accept with Tab.
    var autocompleteEnabled: Bool = false

    // History of recent results (menu-bar submenu)
    var historyEnabled: Bool = true

    // Translation. Source may be "auto" (detect). With an explicit source, the configured pair is
    // bidirectional (text is translated to whichever of source/target it is NOT).
    var sourceLanguage: String = "auto"   // BCP-47 code or "auto"
    var targetLanguage: String = "en"     // BCP-47 code

    // Correct (LanguageTool): a separate, optional action with its own shortcut. The token (if any)
    // lives in the Keychain; only non-secret config is stored here.
    var correctEnabled: Bool = false
    var languageToolBaseURL: String = "https://api.languagetool.org/v2"
    var languageToolUsername: String = ""           // Premium only (account email)
    var languageToolLanguage: String = "auto"        // BCP-47 code or "auto"
    var correctHotkey: HotkeyConfig = .correct

    // Providers
    /// When set, the OpenRouter model list (Fetch) shows only free models.
    var openRouterFreeOnly: Bool = false
    var providers: [ProviderConfig] = [
        .makeDefault(.deepseek),
        .makeDefault(.openrouter),
        .makeDefault(.openai),
        .makeDefault(.ollama),
    ]

    // Hotkeys
    var defaultActionHotkey: HotkeyConfig = .defaultAction
    var translateHotkey: HotkeyConfig = .translate
    var screenTranslateHotkey: HotkeyConfig = .screenTranslate
    var quickTranslateHotkey: HotkeyConfig = .quickTranslate

    func provider(_ kind: ProviderKind) -> ProviderConfig {
        providers.first(where: { $0.kind == kind }) ?? .makeDefault(kind)
    }
}

// MARK: - Resilient decoding

/// Custom decoding so that adding a new setting in a future version does not wipe the user's stored
/// settings: any key missing from the saved JSON simply keeps its default value. Defined in an
/// extension so the implicit `Settings()` initializer is preserved.
extension Settings {
    enum CodingKeys: String, CodingKey {
        case enabled, defaultEngine, separator, defaultPrompt, actionKeys,
             restoreClipboard, maskAISlop, autocompleteEnabled, historyEnabled, sourceLanguage, targetLanguage,
             correctEnabled, languageToolBaseURL, languageToolUsername, languageToolLanguage, correctHotkey,
             openRouterFreeOnly, providers, defaultActionHotkey, translateHotkey,
             screenTranslateHotkey, quickTranslateHotkey
    }

    init(from decoder: Decoder) throws {
        self.init() // start from defaults; only override keys that are present
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try c.decodeIfPresent(Bool.self, forKey: .enabled) { enabled = v }
        if let v = try c.decodeIfPresent(ProviderKind.self, forKey: .defaultEngine) { defaultEngine = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .separator) { separator = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .defaultPrompt) { defaultPrompt = v }
        if let v = try c.decodeIfPresent([ActionKey].self, forKey: .actionKeys) { actionKeys = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .restoreClipboard) { restoreClipboard = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .maskAISlop) { maskAISlop = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .autocompleteEnabled) { autocompleteEnabled = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .historyEnabled) { historyEnabled = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .sourceLanguage) { sourceLanguage = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .targetLanguage) { targetLanguage = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .correctEnabled) { correctEnabled = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .languageToolBaseURL) { languageToolBaseURL = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .languageToolUsername) { languageToolUsername = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .languageToolLanguage) { languageToolLanguage = v }
        if let v = try c.decodeIfPresent(HotkeyConfig.self, forKey: .correctHotkey) { correctHotkey = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .openRouterFreeOnly) { openRouterFreeOnly = v }
        if let v = try c.decodeIfPresent([ProviderConfig].self, forKey: .providers) { providers = v }
        if let v = try c.decodeIfPresent(HotkeyConfig.self, forKey: .defaultActionHotkey) { defaultActionHotkey = v }
        if let v = try c.decodeIfPresent(HotkeyConfig.self, forKey: .translateHotkey) { translateHotkey = v }
        if let v = try c.decodeIfPresent(HotkeyConfig.self, forKey: .screenTranslateHotkey) { screenTranslateHotkey = v }
        if let v = try c.decodeIfPresent(HotkeyConfig.self, forKey: .quickTranslateHotkey) { quickTranslateHotkey = v }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
