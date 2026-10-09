import SwiftUI

struct QuickTranslateOutput: View {
    let output: String
    let needsDownload: Bool
    let copied: Bool
    let copy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                // The placeholder is a separate, non-selectable text: only a real translation can
                // be selected and copied.
                Group {
                    if output.isEmpty {
                        Text("Translation will appear here").foregroundStyle(.secondary)
                    } else {
                        Text(output).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                if needsDownload {
                    Button("Open Language Settings", action: TranslationSupport.openLanguageSettings)
                }
                Spacer()
                Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc", action: copy)
                    .keyboardShortcut("c", modifiers: .control)
                    .disabled(output.isEmpty || needsDownload)
                    .help("Copy the whole translation (Ctrl+C)")
            }
            .controlSize(.small)
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
        }
    }
}
