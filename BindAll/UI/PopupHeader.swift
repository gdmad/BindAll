import SwiftUI

/// The popup's title row, and the only place the panel can be dragged from.
struct PopupHeader: View {
    let title: String
    let languagePair: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(title).bold()
            if let languagePair {
                Text(languagePair).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay { WindowDragHandle() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
