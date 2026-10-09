import SwiftUI

/// Anything typed twice gets learned, typos included; this is how they are found and dropped.
struct TypoFilterRow: View {
    @Binding var onlyTypos: Bool
    let scanning: Bool
    let listedCount: Int
    let removeListed: () -> Void

    @State private var confirmingRemoval = false

    var body: some View {
        HStack {
            Toggle("Only possible typos", isOn: $onlyTypos)
                .toggleStyle(.checkbox)
                .disabled(scanning)
            if scanning {
                ProgressView().controlSize(.small)
            }
            Spacer()
            if onlyTypos, listedCount > 0 {
                Button("Remove all listed", role: .destructive, action: confirmRemoval)
                    .controlSize(.small)
                    .confirmationDialog("Remove ^[\(listedCount) word](inflect: true)?", isPresented: $confirmingRemoval) {
                        Button("Remove", role: .destructive, action: removeListed)
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("They will stop being suggested. Words you pinned by hand are never removed.")
                    }
            }
        }
    }

    private func confirmRemoval() {
        confirmingRemoval = true
    }
}
