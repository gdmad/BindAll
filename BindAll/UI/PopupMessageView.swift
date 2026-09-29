import SwiftUI

/// A one-line notice (checking, no issues, server error) in the same chrome as the fixes list.
struct PopupMessageView: View {
    let text: String
    let fontSize: CGFloat
    let spinner: Bool

    var body: some View {
        HStack(spacing: PopupMetrics.inlineSpacing) {
            if spinner {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel("Working")
            }
            Text(text)
                .font(.system(size: PopupMetrics.secondaryFontSize(fontSize)))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .popupChrome()
    }
}
