import SwiftUI

struct SettingsTabButton: View {
    let tab: SettingsTab
    let isSelected: Bool
    let layout: SettingsTabLayout
    let select: (SettingsTab) -> Void

    var body: some View {
        Button(action: choose) {
            Label(tab.title, systemImage: tab.systemImage)
                .labelStyle(TabLabelStyle(layout: layout))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .background(isSelected ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.clear),
                            in: .rect(cornerRadius: 7))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // Without a visible title it lives in the tooltip, and stays available to VoiceOver.
        .help(layout == .icons ? tab.title : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func choose() {
        select(tab)
    }
}

/// How much room each tab gets, widest first.
enum SettingsTabLayout {
    /// Icon and title side by side.
    case wide
    /// Icon above a small title, as in Safari's or Xcode's settings.
    case stacked
    /// Icon only.
    case icons
}

private struct TabLabelStyle: LabelStyle {
    let layout: SettingsTabLayout
    /// SF Symbols differ in height; a shared box keeps the titles under them on one line.
    @ScaledMetric(relativeTo: .body) private var iconHeight = 18.0

    func makeBody(configuration: Configuration) -> some View {
        switch layout {
        case .wide:
            HStack(spacing: 5) {
                configuration.icon
                configuration.title
            }
        case .stacked:
            VStack(spacing: 2) {
                configuration.icon.frame(height: iconHeight)
                configuration.title.font(.caption)
            }
        case .icons:
            configuration.icon
        }
    }
}
