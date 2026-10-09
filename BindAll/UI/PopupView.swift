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
                Button(action: model.onClose) {
                    Text("Close").frame(minWidth: 56)
                }
                .controlSize(.large)
                Button(action: model.copyText) {
                    Text(model.copiedText ? "Copied" : "Copy").frame(minWidth: 56)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding([.top, .horizontal], 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .onExitCommand(perform: model.onClose)
    }
}
