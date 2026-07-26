import Foundation

/// The apps proofread has actually been verified in, shown on the Proofread tab so users know what
/// to expect before trying.
///
/// Curated by hand -- this is a record of testing, not a guess. Add an entry only after checking, in
/// that app, that: the underlines sit under the right words, clicking one shows its fixes, and
/// applying a fix replaces exactly that word. Use `.fixesOnly` when the app exposes its text but no
/// word coordinates (many Electron and web fields): the popup works, the underlines cannot.
enum ProofreadSupport {
    enum Level {
        /// Underlines and fixes both work.
        case full
        /// Fixes work, but the app reports no word coordinates, so nothing can be underlined.
        case fixesOnly
    }

    struct App {
        let bundleID: String
        let name: String
        let level: Level
        /// A short caveat worth knowing in this app, if any.
        let note: String?
    }

    static let verified: [App] = [
        App(bundleID: "com.apple.TextEdit", name: "TextEdit", level: .full, note: nil),
        App(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", level: .full,
            note: "macOS draws its own red spell squiggles here; ours are purple"),
    ]

    static func entry(for bundleID: String) -> App? {
        verified.first { $0.bundleID == bundleID }
    }
}
