import SwiftUI

/// A compact language menu; `title` is for VoiceOver only.
struct LanguagePicker: View {
    let title: String
    @Binding var selection: String
    let includeAuto: Bool

    var body: some View {
        Picker(title, selection: $selection) {
            if includeAuto { Text("Auto Detect").tag(AppLanguages.autoTag) }
            ForEach(AppLanguages.list, id: \.code) { language in
                Text(language.name).tag(language.code)
            }
        }
        .labelsHidden()
        .fixedSize()
    }
}
