import SwiftUI

struct SettingsTabContent: View {
    let tab: SettingsTab

    var body: some View {
        switch tab {
        case .general: GeneralSettingsView()
        case .actions: ActionsSettingsView()
        case .translation: TranslationSettingsView()
        case .autocomplete: AutocompleteSettingsView()
        case .proofread: ProofreadSettingsView()
        case .providers: ProvidersSettingsView()
        }
    }
}
