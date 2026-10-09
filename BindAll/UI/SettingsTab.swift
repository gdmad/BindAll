import Foundation

/// The settings sections, in tab-bar order. Every feature owns one tab, and that tab carries
/// everything about it -- starting with its own on/off switch.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, actions, translation, autocomplete, proofread, providers

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .actions: "Actions"
        case .translation: "Translation"
        case .autocomplete: "Autocomplete"
        case .proofread: "Proofread"
        case .providers: "Providers"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .actions: "text.badge.checkmark"
        case .translation: "globe"
        case .autocomplete: "text.append"
        case .proofread: "text.magnifyingglass"
        case .providers: "cloud"
        }
    }
}
