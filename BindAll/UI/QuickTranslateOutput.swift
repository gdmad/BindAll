import SwiftUI

struct QuickTranslateOutput: View {
    let output: String

    var body: some View {
        ScrollView {
            // The placeholder is a separate, non-selectable text: only a real translation can be
            // selected and copied.
            Group {
                if output.isEmpty {
                    Text("Translation will appear here").foregroundStyle(.secondary)
                } else {
                    Text(output).textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
