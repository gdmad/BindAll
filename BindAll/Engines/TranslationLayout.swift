import Foundation

/// Puts the source's line breaks back into a translation. Apple's on-device model (macOS 27)
/// treats every line as its own segment and joins its output with blank lines, so "Hi!\nHow\nare
/// you?" came back with an empty line between every line. The translation itself is left alone;
/// only the runs of newlines between its pieces are replaced.
enum TranslationLayout {
    /// The runs of consecutive newlines in `text`, in order (each run as written, "\n" or "\n\n"...).
    static func newlineRuns(in text: String) -> [String] {
        var runs: [String] = []
        var current = ""
        for character in text {
            if character.isNewline {
                current.append(character)
            } else if !current.isEmpty {
                runs.append(current)
                current = ""
            }
        }
        return runs // a trailing run is not between two pieces, so it is left out
    }

    /// `translation` with its newline runs replaced by the source's. When the model kept the number
    /// of breaks, each one maps onto the source's run at the same position; when it merged or split
    /// some, every run is capped at the longest one the source has, so a source without blank lines
    /// never gets any.
    static func restore(source: String, translation: String) -> String {
        let sourceRuns = newlineRuns(in: source.trimmingCharacters(in: .newlines))
        let trimmed = translation.trimmingCharacters(in: .newlines)
        let translatedRuns = newlineRuns(in: trimmed)
        guard !translatedRuns.isEmpty else { return trimmed }

        let longest = sourceRuns.map(\.count).max() ?? 1
        var replacements = sourceRuns.count == translatedRuns.count
            ? sourceRuns
            : translatedRuns.map { String(repeating: "\n", count: min($0.count, longest)) }
        replacements.reverse()

        var out = ""
        var inRun = false
        for character in trimmed {
            if character.isNewline {
                if !inRun { out += replacements.popLast() ?? "\n" }
                inRun = true
            } else {
                inRun = false
                out.append(character)
            }
        }
        return out
    }
}
