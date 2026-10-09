import SwiftUI

struct HistoryRow: View {
    let entry: HistoryEntry
    let isExpanded: Bool
    let toggle: () -> Void
    let onCopy: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 3)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(preview)
                            .lineLimit(1)
                        Text("\(entry.kind.label) · \(entry.engine)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                HistoryDetail(title: "Request", text: entry.input, onCopy: onCopy)
                HistoryDetail(title: "Result", text: entry.output, onCopy: onCopy)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var preview: String {
        entry.output.replacing("\n", with: " ").trimmingCharacters(in: .whitespaces)
    }
}
