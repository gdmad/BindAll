import SwiftUI
import Translation

struct QuickTranslateView: View {
    @Bindable var model: QuickTranslateModel
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            QuickTranslateLanguageBar(source: $model.source, target: $model.target, swap: model.swapLanguages)
            Divider()
            QuickTranslateInput(text: $model.input, focused: $inputFocused, submit: model.translate)
            Divider()
            QuickTranslateOutput(output: model.output)
            QuickTranslateActionBar(model: model, clear: clear)
            Divider()
            QuickTranslateFooter(isTranslating: model.isTranslating)
        }
        .frame(minWidth: 420, minHeight: 380)
        .background(.regularMaterial)
        .ignoresSafeArea()
        // Host the translation session in this visible window so the language-download prompt can
        // appear and be confirmed here (an offscreen host makes it flash and fail).
        .translationTask(model.translation.configuration) { session in
            await model.translation.run(with: session)
        }
        .onExitCommand(perform: model.onClose)
        .onAppear { inputFocused = true }
    }

    private func clear() {
        model.clear()
        inputFocused = true
    }
}
