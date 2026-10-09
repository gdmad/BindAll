import SwiftUI

/// The primary button of every translation window: copies the whole result (⌘C does the same when
/// nothing is selected, see `CopyShortcutMonitor`).
struct CopyButton: View {
    let copied: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(copied ? "Copied" : "Copy").frame(minWidth: 56)
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .help("Copy the whole text (⌘C)")
    }
}
