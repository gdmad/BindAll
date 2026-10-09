import SwiftUI

/// One row of tab buttons in a given layout; `SettingsTabBar` offers it in several and keeps the
/// widest that fits.
struct SettingsTabRow: View {
    @Binding var selection: SettingsTab
    let layout: SettingsTabLayout

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases) { tab in
                SettingsTabButton(tab: tab, isSelected: tab == selection, layout: layout, select: select)
            }
        }
        .fixedSize()
    }

    private func select(_ tab: SettingsTab) {
        selection = tab
    }
}
