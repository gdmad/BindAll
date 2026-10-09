import SwiftUI

struct SettingsView: View {
    /// Wide enough for the tab titles; narrower windows fall back to icons.
    static let defaultSize = CGSize(width: 660, height: 558)

    @State private var selection: SettingsTab = .general

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(selection: $selection)
            Divider()
            SettingsTabContent(tab: selection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 440, idealWidth: Self.defaultSize.width, minHeight: 478, idealHeight: Self.defaultSize.height)
    }
}
