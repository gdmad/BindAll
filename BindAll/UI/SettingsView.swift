import SwiftUI

struct SettingsView: View {
    /// Every feature owns one tab, and that tab carries everything about it -- starting with its own
    /// on/off switch. General is left with what belongs to the app as a whole.
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettingsView() }
            Tab("Actions", systemImage: "text.badge.checkmark") { ActionsSettingsView() }
            Tab("Translation", systemImage: "globe") { TranslationSettingsView() }
            Tab("Autocomplete", systemImage: "text.append") { AutocompleteSettingsView() }
            Tab("Proofread", systemImage: "text.magnifyingglass") { ProofreadSettingsView() }
            Tab("Providers", systemImage: "cloud") { ProvidersSettingsView() }
        }
        .padding(.top, 8)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 478, idealHeight: 558)
    }
}
