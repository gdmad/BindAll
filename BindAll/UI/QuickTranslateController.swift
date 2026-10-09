import AppKit
import SwiftUI
import Translation

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
