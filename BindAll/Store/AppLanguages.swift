import Foundation

/// Languages offered in the translation UIs (native names, ordered like Apple's translation list).
enum AppLanguages {
    static let autoTag = "auto"

    static let list: [(code: String, name: String)] = [
        ("en", "English"),
        ("ru", "Russian"),
        ("uk", "Ukrainian"),
        ("de", "German"),
        ("fr", "French"),
        ("es", "Spanish"),
        ("it", "Italian"),
        ("pt", "Portuguese"),
        ("nl", "Dutch"),
        ("pl", "Polish"),
        ("tr", "Turkish"),
        ("ar", "Arabic"),
        ("hi", "Hindi"),
        ("id", "Indonesian"),
        ("th", "Thai"),
        ("vi", "Vietnamese"),
        ("ko", "Korean"),
        ("ja", "Japanese"),
        ("zh-Hans", "Chinese (Simplified)"),
        ("zh-Hant", "Chinese (Traditional)"),
    ]

    static func name(for code: String) -> String {
        if code == autoTag { return "Auto Detect" }
        return list.first(where: { $0.code == code })?.name ?? code
    }
}
