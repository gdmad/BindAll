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
                ContentUnavailableView("No History Yet", systemImage: "clock",
                                       description: Text("Results of actions and translations appear here."))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            HistoryRow(entry: entry, isExpanded: expandedID == entry.id,
                                       toggle: { toggle(entry.id) }, onCopy: onCopy)
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(width: 340, height: 380)
    }

    private func toggle(_ id: HistoryEntry.ID) {
        expandedID = expandedID == id ? nil : id
    }
}
