import SwiftUI

/// The settings tabs, drawn in the window rather than by `TabView`: on macOS 26 and later a
/// `TabView` built from `Tab` moves them into the title bar as icons that overflow behind a "»"
/// menu. Titles are shown while they fit (beside the icon, then under it); a narrow window shows
/// icons only -- never an overflow menu.
struct SettingsTabBar: View {
    @Binding var selection: SettingsTab

    var body: some View {
        ViewThatFits(in: .horizontal) {
            SettingsTabRow(selection: $selection, layout: .wide)
            SettingsTabRow(selection: $selection, layout: .stacked)
            SettingsTabRow(selection: $selection, layout: .icons)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
