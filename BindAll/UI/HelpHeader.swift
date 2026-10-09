import SwiftUI

/// A section header (or row label) with a trailing help icon.
struct HelpHeader: View {
    let title: String
    let help: String

    init(_ title: String, _ help: String) {
        self.title = title
        self.help = help
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            HelpHint(help)
        }
    }
}
