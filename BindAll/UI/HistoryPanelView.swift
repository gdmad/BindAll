import SwiftUI

/// Floating History panel shown from the menu bar. Each row expands to reveal the original request
/// and the full result, each with its own Copy button.
struct HistoryPanelView: View {
    let entries: [HistoryEntry]
    /// Copies the given text to the clipboard and closes the panel.
    let onCopy: (String) -> Void
    let onClear: () -> Void

    @State private var expandedID: HistoryEntry.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("History").font(.headline)
                Spacer()
                if !entries.isEmpty {
                    Button("Clear", action: onClear).controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if entries.isEmpty {
                Text("No history yet")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            row(entry)
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(width: 340, height: 380)
    }

    @ViewBuilder
    private func row(_ entry: HistoryEntry) -> some View {
        let isExpanded = expandedID == entry.id

        VStack(alignment: .leading, spacing: 6) {
            Button {
                expandedID = isExpanded ? nil : entry.id
            } label: {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(preview(entry.output))
                            .lineLimit(isExpanded ? nil : 2)
                            .font(.body)
                        Text("\(entry.kind.label) · \(entry.engine)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                detail(title: "Request", text: entry.input)
                detail(title: "Result", text: entry.output)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private func detail(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    onCopy(text)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc").labelStyle(.titleAndIcon)
                }
                .controlSize(.small)
            }
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
        }
    }

    private func preview(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }
}
