import SwiftUI

/// Quick Translate's buttons. Close and Copy are the same `CloseButton` / `CopyButton` the
/// translation popup uses; Clear exists only here, because only this window has an input.
struct QuickTranslateActionBar: View {
    let model: QuickTranslateModel
    let clear: () -> Void

    var body: some View {
        // Copy, the main action, is rightmost with Close next to it; Clear throws the text away, so
        // it sits apart on the left rather than one slip away from Copy.
        HStack(spacing: 10) {
            Button(action: clear) {
                Text("Clear").frame(minWidth: 56)
            }
            .controlSize(.large)
            .disabled(!model.canClear)
            .help("Clear the text and its translation")
            if model.needsDownload {
                Button("Open Language Settings", action: TranslationSupport.openLanguageSettings)
            }
            Spacer()
            CloseButton(action: model.onClose)
            CopyButton(copied: model.copied, action: model.copyOutput)
                .disabled(!model.canCopy)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
