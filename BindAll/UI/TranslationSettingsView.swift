import SwiftUI

struct TranslationSettingsView: View {
    var body: some View {
        Form {
            TranslationSection()
        }
        .formStyle(.grouped)
    }
}
