import Foundation

/// The resolved instruction + content extracted from a selection.
struct ParsedAction: Equatable {
    /// The text to operate on.
    var content: String
    /// The instruction/prompt to apply.
    var instruction: String
    /// True when an explicit instruction (separator) was present; false means the default prompt.
    var hadExplicitInstruction: Bool
}

/// Splits selected text on the configured separator and resolves trailing action keys.
///
/// Rules:
/// - No separator  → operate on the whole text using `defaultPrompt`.
/// - `content -- suffix` → if `suffix` matches an `ActionKey.key`, use that key's prompt on `content`;
///   otherwise treat `suffix` as a freeform instruction applied to `content`.
enum PromptParser {
    static func parse(
        text: String,
        separator: String,
        defaultPrompt: String,
        actionKeys: [ActionKey]
    ) -> ParsedAction {
        let trimmedSeparator = separator.trimmingCharacters(in: .whitespaces)
        guard !trimmedSeparator.isEmpty,
              let range = text.range(of: trimmedSeparator, options: .backwards) else {
            return ParsedAction(
                content: text.trimmingCharacters(in: .whitespacesAndNewlines),
                instruction: defaultPrompt,
                hadExplicitInstruction: false
            )
        }

        let content = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Empty content or empty suffix → treat the whole thing as plain text for the default prompt.
        guard !content.isEmpty, !suffix.isEmpty else {
            return ParsedAction(
                content: text.trimmingCharacters(in: .whitespacesAndNewlines),
                instruction: defaultPrompt,
                hadExplicitInstruction: false
            )
        }

        if let key = actionKeys.first(where: { $0.key.caseInsensitiveCompare(suffix) == .orderedSame }) {
            return ParsedAction(content: content, instruction: key.prompt, hadExplicitInstruction: true)
        }

        // Freeform instruction.
        let instruction = "\(suffix). Output only the resulting text, with no explanations."
        return ParsedAction(content: content, instruction: instruction, hadExplicitInstruction: true)
    }
}
