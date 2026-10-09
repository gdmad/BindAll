import SwiftUI

/// Quick Translate's buttons. Close and Copy are the same `CloseButton` / `CopyButton` the
/// translation popup uses; Clear exists only here, because only this window has an input.
struct QuickTranslateActionBar: View {
    let model: QuickTranslateModel
    let clear: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if model.needsDownload {
                Button("Open Language Settings", action: TranslationSupport.openLanguageSettings)
            }
            Spacer()
            Button(action: clear) {
                Text("Clear").frame(minWidth: 56)
            }
            .controlSize(.large)
            .disabled(!model.canClear)
            .help("Clear the text and its translation")
            CloseButton(action: model.onClose)
            CopyButton(copied: model.copied, action: model.copyOutput)
                .disabled(!model.canCopy)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
