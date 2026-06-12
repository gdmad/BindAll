import AppKit
import SwiftUI
import Translation

/// A panel that can become key (so the user can type), even from an accessory (menu-bar) app.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Shows the Quick Translate window: type text, pick languages, translate on-device.
@MainActor
final class QuickTranslateController: NSObject, NSWindowDelegate {
    private let appState: AppState
    private var window: NSWindow?

    init(appState: AppState) {
        self.appState = appState
    }

    func toggle() {
        if window != nil { close() } else { show() }
    }

    func show() {
        if let window {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let view = QuickTranslateView(
            initialSource: appState.settings.sourceLanguage,
            initialTarget: appState.settings.targetLanguage,
            onClose: { [weak self] in self?.close() },
            onTranslated: { [weak self] input, output in
                guard let self, self.appState.settings.historyEnabled else { return }
                HistoryStore.shared.record(kind: .quick, input: input, output: output, engine: "Apple Translation")
            }
        )
        let hosting = NSHostingController(rootView: view)
        // A regular window (not a floating panel) so the system language-download sheet attaches and
        // stays put; floating panels make that sheet flash and fail.
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { window.standardWindowButton($0)?.isHidden = true }
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 460, height: 430))
        window.center()
        self.window = window

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.orderOut(nil)
        window = nil
        NSApp.setActivationPolicy(.accessory)
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        window = nil
        NSApp.setActivationPolicy(.accessory)
    }
}

struct QuickTranslateView: View {
    let onClose: () -> Void
    let onTranslated: (String, String) -> Void

    @StateObject private var translation = TranslationCoordinator()
    @State private var source: String
    @State private var target: String
    @State private var input: String = ""
    @State private var output: String = ""
    @State private var isTranslating = false
    @State private var needsDownload = false
    @FocusState private var inputFocused: Bool

    private static let autoTag = "auto"

    init(initialSource: String, initialTarget: String,
         onClose: @escaping () -> Void,
         onTranslated: @escaping (String, String) -> Void = { _, _ in }) {
        self.onClose = onClose
        self.onTranslated = onTranslated
        _source = State(initialValue: initialSource)
        _target = State(initialValue: initialTarget)
    }

    var body: some View {
        VStack(spacing: 0) {
            languageBar
            Divider()
            inputArea
            Divider()
            outputArea
            Divider()
            footer
        }
        .frame(minWidth: 420, minHeight: 380)
        .background(.regularMaterial)
        .ignoresSafeArea()
        // Host the translation session in this visible window so the language-download prompt can
        // appear and be confirmed here (an offscreen host makes it flash and fail).
        .translationTask(translation.configuration) { session in
            await translation.run(with: session)
        }
        .onExitCommand { onClose() }
        .onAppear { inputFocused = true }
    }

    private var languageBar: some View {
        HStack(spacing: 8) {
            Picker("", selection: $source) {
                Text("Auto").tag(Self.autoTag)
                ForEach(AppLanguages.list, id: \.code) { Text($0.name).tag($0.code) }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)

            Button { swapLanguages() } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("/", modifiers: .command)
            .disabled(source == Self.autoTag)
            .help("Swap languages (Cmd+/)")

            Picker("", selection: $target) {
                ForEach(AppLanguages.list, id: \.code) { Text($0.name).tag($0.code) }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
        }
        .padding(12)
    }

    private var inputArea: some View {
        TextEditor(text: $input)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .focused($inputFocused)
            .overlay(alignment: .topLeading) {
                if input.isEmpty {
                    Text("Type text to translate...")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }
            .onKeyPress(keys: [.return]) { press in
                if press.modifiers.contains(.shift) { return .ignored }
                translate()
                return .handled
            }
    }

    private var outputArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                Text(output.isEmpty ? "Translation will appear here" : output)
                    .foregroundStyle(output.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if needsDownload {
                Button("Open Language Settings") {
                    TranslationSupport.openLanguageSettings()
                }
                .controlSize(.small)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("ESC: close")
            Text("Enter: translate")
            Text("⇧Enter: new line")
            Text("⌘/: swap")
            Spacer()
            if isTranslating { ProgressView().controlSize(.small) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func swapLanguages() {
        guard source != Self.autoTag else { return }
        let old = source
        source = target
        target = old
        if !output.isEmpty { translate() }
    }

    private func translate() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isTranslating = true
        needsDownload = false
        output = ""
        let src: Locale.Language = source == Self.autoTag
            ? (LanguageDetector.detect(text) ?? Locale.Language(identifier: "en"))
            : Locale.Language(identifier: source)
        let tgt = Locale.Language(identifier: target)
        Task {
            if await TranslationSupport.isInstalled(from: src, to: tgt) {
                do {
                    output = try await translation.translate(text, from: src, to: tgt)
                    onTranslated(text, output)
                } catch {
                    output = error.localizedDescription
                }
            } else {
                needsDownload = true
                let from = AppLanguages.name(for: src.languageCode?.identifier ?? "")
                let to = AppLanguages.name(for: target)
                output = "\(from) -> \(to) is not downloaded yet. Download it once in System Settings, then translation works offline."
            }
            isTranslating = false
        }
    }
}
