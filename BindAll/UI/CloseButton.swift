import SwiftUI

/// Closes a translation window; Esc does the same.
struct CloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Close").frame(minWidth: 56)
        }
        .controlSize(.large)
        .help("Close (Esc)")
    }
}
