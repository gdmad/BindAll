import SwiftUI

struct LearnedWordRow: View {
    let word: String
    let count: Int
    let isSuspect: Bool
    let remove: (String) -> Void

    var body: some View {
        HStack {
            if isSuspect {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("The dictionary does not know this word")
                    .accessibilityLabel("Possible typo")
            }
            Text(word)
            Spacer()
            Group {
                if count >= LearnedWordAudit.pinnedWeight {
                    Text("pinned")
                } else {
                    Text(count, format: .number)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Button("Remove \(word)", systemImage: "minus.circle.fill", action: removeWord)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
    }

    private func removeWord() {
        remove(word)
    }
}
