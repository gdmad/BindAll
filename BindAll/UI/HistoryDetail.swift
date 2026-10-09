import SwiftUI

/// One block of an expanded history row (the request or the result) with its own Copy button.
struct HistoryDetail: View {
    let title: String
    let text: String
    let onCopy: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Copy", systemImage: "doc.on.doc", action: copy)
                    .labelStyle(.titleAndIcon)
                    .controlSize(.small)
            }
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quinary, in: .rect(cornerRadius: 6))
        }
    }

    private func copy() {
        onCopy(text)
    }
}
