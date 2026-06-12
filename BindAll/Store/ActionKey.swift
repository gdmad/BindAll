import Foundation

/// A short user-defined shortcut that expands to a full instruction/prompt.
///
/// Example: key `w` with a layout-fix prompt so the user can write
/// `Ghbdtn rfr ltkf -- w` and have the trailing `w` resolved to the full instruction.
struct ActionKey: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var key: String
    var label: String
    var prompt: String
    /// Optional global shortcut that runs this action on the current selection directly,
    /// without typing the separator suffix. Decodes as nil from older stored settings.
    var hotkey: HotkeyConfig?

    static let defaults: [ActionKey] = [
        ActionKey(
            key: "w",
            label: "Fix keyboard layout",
            prompt: "Convert this wrong-keyboard-layout text to the intended layout (e.g. Ghbdtn -> Привет). Output only the result."
        ),
        ActionKey(
            key: "u",
            label: "UPPERCASE",
            prompt: "Convert the text to UPPERCASE. Output only the result."
        ),
        ActionKey(
            key: "l",
            label: "lowercase",
            prompt: "Convert the text to lowercase. Output only the result."
        ),
        ActionKey(
            key: "о",
            label: "Formal tone",
            prompt: "Rewrite in a formal, professional tone. Same language. Output only the result."
        ),
        ActionKey(
            key: "гг",
            label: "Polite request",
            prompt: "Rewrite the text as a short, polite, constructive request. Start with \"Привет!\" and form a complete question or request (e.g. \"когда\" -> \"Привет! Когда будет готово?\", \"пришли отчет\" -> \"Привет! Можешь прислать отчёт?\"). Same language. Output only the result."
        ),
    ]
}
