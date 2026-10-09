import SwiftUI

struct QuickTranslateFooter: View {
    let isTranslating: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text("ESC: close")
            Text("Enter: translate")
            Text("⇧Enter: new line")
            Text("⌘/: swap")
            Text("⌘C: copy")
            Spacer()
            if isTranslating { ProgressView().controlSize(.small) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
