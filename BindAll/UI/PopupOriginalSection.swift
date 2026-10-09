import SwiftUI

struct PopupOriginalSection: View {
    let original: String
    let language: String?
    let copied: Bool
    let copy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Original")
                Button(copied ? "Copied" : "Copy original", systemImage: copied ? "checkmark" : "doc.on.doc",
                       action: copy)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Copy the original text")
                Spacer()
                if let language {
                    Text(language)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            ScrollView {
                Text(original)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(.secondary)
            }
            .frame(maxHeight: .infinity)
        }
    }
}
