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
}

// MARK: - LanguageTool connection

/// How BindAll reaches LanguageTool. The three ways need different fields, and mixing them up is the
/// usual source of trouble: the free public server rejects any credentials (HTTP 400), while Premium
/// lives on a *different* host and requires them. Making the mode explicit lets the UI show only the
/// relevant fields and lets the resolver never send credentials where they do not belong.
enum LanguageToolMode: String, Codable, CaseIterable {
    case free
    case premium
    case selfHosted

    var displayName: String {
        switch self {
        case .free: return "Free public"
        case .premium: return "Premium"
        case .selfHosted: return "Self-hosted"
        }
    }

    /// The URL pre-filled when the user picks this mode; nil for self-hosted (keeps the current URL).
    /// The field stays editable, so this is only a starting point.
    var defaultURL: String? {
        switch self {
        case .free: return "https://api.languagetool.org/v2"
        case .premium: return "https://api.languagetoolplus.com/v2"
        case .selfHosted: return nil
        }
    }
}

// MARK: - Popup layout

/// How the floating popups arrange their items. Shared by autocomplete suggestions and proofread
/// fixes, so both feature the same three looks.
enum PopupLayout: String, Codable, CaseIterable {
    case column
    case line
    case tile

    var displayName: String {
        switch self {
        case .column: return "Column"
        case .line: return "Line"
        case .tile: return "Tile (2 rows)"
        }
    }

    /// Columns in tile mode: the grid is exactly two rows, filled left to right.
    static func tileColumns(forCount count: Int) -> Int {
        max(1, (count + 1) / 2)
    }

    /// Moves a selection by `deltaX`/`deltaY` steps inside a two-row tile grid of `count` items.
    /// Horizontal movement walks the row-major order and wraps; vertical movement steps a whole row
    /// (columns) and clamps at the ends. `topRowCount` overrides the column count with the number of
    /// items actually placed on the first row (a width-measured split); 0 falls back to the even
    /// `tileColumns` split. When everything fits on one row there is no second row to move to, so
    /// vertical movement does nothing rather than jumping to the far end of the single row.
    static func tileIndex(from index: Int, deltaX: Int, deltaY: Int, count: Int,
                          topRowCount: Int = 0) -> Int {
        guard count > 0 else { return 0 }
        let clamped = max(0, min(index, count - 1))
        if deltaX != 0 { return (clamped + deltaX + count) % count }
        if deltaY != 0 {
            let columns = topRowCount > 0 ? min(topRowCount, count) : tileColumns(forCount: count)
            guard columns < count else { return clamped }
            return max(0, min(count - 1, clamped + deltaY * columns))
        }
        return clamped
    }
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

    // Suggest a completion for the word being typed, accept with Tab.
    var autocompleteEnabled: Bool = false
    var autocompleteCount: Int = 5            // how many suggestions to show (1...9)
    var popupFontSize: Int = 13               // text size in both popups: autocomplete and proofread (10...20)
    var autocompleteLayout: PopupLayout = .column  // how the suggestions are arranged
    var autocompleteLanguages: [String] = []  // dictionary languages (BCP-47); empty = auto-detect
    var autocompleteLearn: Bool = true        // learn accepted/typed words and rank them
    var autocompleteNextWord: Bool = true     // predict the next word after a space
    var autocompleteAcceptReturn: Bool = true // accept with Return in addition to Tab
    var autocompleteContextRanking: Bool = true // rank completions by the preceding words (n-grams)
    var autocompleteAppMode: String = "all"   // "all" | "allow" | "deny"
    var autocompleteApps: [String] = []       // bundle identifiers for allow/deny

    // Proofread behaviour. Whether it runs at all, the server and the language come from the
    // LanguageTool settings below; there is no shortcut, it checks as you type.
    var proofreadMaxReplacements: Int = 3      // fixes listed per issue (1...10)
    var proofreadLayout: PopupLayout = .column // how the fixes are arranged in the popup
    var proofreadMinLength: Int = 12           // shortest text worth checking
    var proofreadAppMode: String = "all"       // "all" | "allow" | "deny"
    var proofreadApps: [String] = []           // bundle identifiers for allow/deny

    // History of recent results (menu-bar submenu)
    var historyEnabled: Bool = true

    // Translation. Source may be "auto" (detect). With an explicit source, the configured pair is
    // bidirectional (text is translated to whichever of source/target it is NOT).
    var sourceLanguage: String = "auto"   // BCP-47 code or "auto"
    var targetLanguage: String = "en"     // BCP-47 code

    // Proofread (LanguageTool): optional, has no shortcut -- it checks as you type. The token (if
    // any) lives in the Keychain; only non-secret config is stored here.
    var correctEnabled: Bool = false
    var languageToolMode: LanguageToolMode = .free
    var languageToolBaseURL: String = "https://api.languagetool.org/v2"  // used only in self-hosted mode
    var languageToolUsername: String = ""           // Premium account email
    var languageToolLanguage: String = "auto"        // BCP-47 code or "auto"

    /// The base URL, username and apiKey to actually put on the wire, resolved from the mode.
    /// Only Premium sends credentials: the public server rejects them, and a self-hosted server is
    /// reached by URL alone. `token` is read from the Keychain by the caller.
    func languageToolConnection(token: String) -> (baseURL: String, username: String, apiKey: String) {
        switch languageToolMode {
        case .free, .selfHosted:
            return (languageToolBaseURL, "", "")
        case .premium:
            return (languageToolBaseURL, languageToolUsername, token)
        }
    }

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
             restoreClipboard, maskAISlop, autocompleteEnabled, autocompleteCount, autocompleteLayout,
             popupFontSize, autocompleteLanguages, autocompleteLearn, autocompleteNextWord,
             autocompleteAcceptReturn, autocompleteContextRanking, autocompleteAppMode, autocompleteApps,
             proofreadMaxReplacements, proofreadLayout,
             proofreadMinLength, proofreadAppMode, proofreadApps,
             historyEnabled, sourceLanguage, targetLanguage,
             correctEnabled, languageToolMode, languageToolBaseURL, languageToolUsername, languageToolLanguage,
             openRouterFreeOnly, providers, defaultActionHotkey, translateHotkey,
             screenTranslateHotkey, quickTranslateHotkey
    }

    /// Old key names still honoured on decode (never written back).
    private enum LegacyKeys: String, CodingKey {
        case autocompleteFontSize
        case autocompleteHorizontal
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
        if let v = try c.decodeIfPresent(Int.self, forKey: .autocompleteCount) { autocompleteCount = v }
        if let v = try c.decodeIfPresent(PopupLayout.self, forKey: .autocompleteLayout) {
            autocompleteLayout = v
        } else if let legacy = try? decoder.container(keyedBy: LegacyKeys.self),
                  let v = try legacy.decodeIfPresent(Bool.self, forKey: .autocompleteHorizontal) {
            autocompleteLayout = v ? .line : .column
        }
        // autocompleteFontSize is the legacy name of popupFontSize (it now drives both popups).
        if let v = try c.decodeIfPresent(Int.self, forKey: .popupFontSize) {
            popupFontSize = v
        } else if let legacy = try? decoder.container(keyedBy: LegacyKeys.self),
                  let v = try legacy.decodeIfPresent(Int.self, forKey: .autocompleteFontSize) {
            popupFontSize = v
        }
        if let v = try c.decodeIfPresent([String].self, forKey: .autocompleteLanguages) { autocompleteLanguages = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .autocompleteLearn) { autocompleteLearn = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .autocompleteNextWord) { autocompleteNextWord = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .autocompleteAcceptReturn) { autocompleteAcceptReturn = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .autocompleteContextRanking) { autocompleteContextRanking = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .autocompleteAppMode) { autocompleteAppMode = v }
        if let v = try c.decodeIfPresent([String].self, forKey: .autocompleteApps) { autocompleteApps = v }
        if let v = try c.decodeIfPresent(Int.self, forKey: .proofreadMaxReplacements) { proofreadMaxReplacements = v }
        if let v = try c.decodeIfPresent(PopupLayout.self, forKey: .proofreadLayout) { proofreadLayout = v }
        if let v = try c.decodeIfPresent(Int.self, forKey: .proofreadMinLength) { proofreadMinLength = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .proofreadAppMode) { proofreadAppMode = v }
        if let v = try c.decodeIfPresent([String].self, forKey: .proofreadApps) { proofreadApps = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .historyEnabled) { historyEnabled = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .sourceLanguage) { sourceLanguage = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .targetLanguage) { targetLanguage = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .correctEnabled) { correctEnabled = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .languageToolBaseURL) { languageToolBaseURL = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .languageToolUsername) { languageToolUsername = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .languageToolLanguage) { languageToolLanguage = v }
        if let v = try c.decodeIfPresent(LanguageToolMode.self, forKey: .languageToolMode) { languageToolMode = v }
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
