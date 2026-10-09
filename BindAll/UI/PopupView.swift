import SwiftUI

struct PopupView: View {
    @Bindable var model: PopupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PopupHeader(title: model.title, languagePair: model.languagePair)

            ScrollView {
                Text(model.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)

            if model.showOriginal, let original = model.original {
                Divider()
                PopupOriginalSection(original: original, language: model.sourceLanguage,
                                     copied: model.copiedOriginal, copy: model.copyOriginal)
            }

            HStack(spacing: 10) {
                if model.original != nil {
                    Toggle("Show Original", isOn: $model.showOriginal)
                        .toggleStyle(.checkbox)
                }
                Spacer()
                CloseButton(action: model.onClose)
                CopyButton(copied: model.copiedText, action: model.copyText)
            }
        }
        .padding([.top, .horizontal], 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .onExitCommand(perform: model.onClose)
    }
}
