import Foundation

/// Issues the user chose to skip ("not here"), remembered for this run of BindAll. An issue is
/// identified by its rule, its text and a few characters either side -- not by its range, which
/// moves as soon as anything before it is edited -- so a skipped place stays skipped across
/// re-checks while the same word elsewhere is still underlined.
struct ProofreadSkips {
    private(set) var keys: Set<String> = []

    /// Characters of context on each side that tell two identical words apart.
    static let contextSpan = 6

    static func key(for issue: TextIssue) -> String {
        "\(issue.ruleId ?? "")|\(issue.original)|\(issue.contextBefore.suffix(contextSpan))|\(issue.contextAfter.prefix(contextSpan))"
    }

    mutating func insert(_ issue: TextIssue) {
        keys.insert(Self.key(for: issue))
    }

    func filter(_ issues: [TextIssue]) -> [TextIssue] {
        guard !keys.isEmpty else { return issues }
        return issues.filter { !keys.contains(Self.key(for: $0)) }
    }
}
