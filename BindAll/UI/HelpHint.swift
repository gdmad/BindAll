import SwiftUI

/// A small question-mark icon that reveals `text` on click (popover).
struct HelpHint: View {
    let text: String
    @State private var showPopover = false

    init(_ text: String) { self.text = text }

    var body: some View {
        Button("Help", systemImage: "questionmark.circle", action: togglePopover)
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .popover(isPresented: $showPopover, arrowEdge: .bottom) {
                Text(text)
                    .font(.callout)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 280)
                    .padding(12)
            }
    }

    private func togglePopover() {
        showPopover.toggle()
    }
}
