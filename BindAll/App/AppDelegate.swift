import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    let appState = AppState()
    private(set) lazy var coordinator = HotkeyCoordinator(appState: appState)

    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var pulseTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    /// SF Symbol shown when idle.
    private let idleSymbol = "text.cursor"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        coordinator.start()
        // Ask for Accessibility up front (needed for the global hotkeys); the system shows its prompt
        // only if not yet granted. No window is opened automatically.
        AccessibilityPermission.requestIfNeeded()

        // Swap the menu-bar icon while an action is being processed.
        appState.$isProcessing
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] busy in self?.updateStatusIcon(busy: busy) }
            .store(in: &cancellables)
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stop()
    }

    // MARK: - Status bar item

    private func setupStatusItem() {
        // Variable length so the item hugs the icon (keeps the click highlight tight, not an oval).
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        updateStatusIcon(busy: false)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        rebuildMenu()
    }

    /// The icon is the button's own image, so the system click highlight and template inversion
    /// work correctly. While busy, the sparkles icon pulses via the button's alpha (symbol-effect
    /// animations would require an overlay view, which breaks the highlight).
    private func updateStatusIcon(busy: Bool) {
        guard let button = statusItem?.button else { return }
        let symbol = busy ? "sparkles" : idleSymbol
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        var image = NSImage(systemSymbolName: symbol, accessibilityDescription: busy ? "BindAll — working" : "BindAll")
        image = image?.withSymbolConfiguration(config)
        image?.isTemplate = true
        button.image = image

        pulseTimer?.invalidate()
        pulseTimer = nil
        if busy {
            var dimmed = false
            pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { _ in
                Task { @MainActor in
                    guard let button = self.statusItem?.button else { return }
                    dimmed.toggle()
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.4
                        button.animator().alphaValue = dimmed ? 0.4 : 1.0
                    }
                }
            }
        } else {
            button.alphaValue = 1.0
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        coordinator.refreshStatus()
        rebuildMenu()
    }

    private func rebuildMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()

        let enabled = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        enabled.target = self
        enabled.state = appState.settings.enabled ? .on : .off
        menu.addItem(enabled)

        // Only surface the Accessibility action when it still needs granting (first run / re-sign).
        if !appState.accessibilityGranted {
            let grant = NSMenuItem(title: "Grant Accessibility…", action: #selector(grantAccessibility), keyEquivalent: "")
            grant.target = self
            menu.addItem(grant)
        }

        if appState.settings.historyEnabled {
            let history = NSMenuItem(title: "History", action: nil, keyEquivalent: "")
            history.submenu = buildHistorySubmenu()
            menu.addItem(history)
        }

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(title: "Quit BindAll", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// Builds the History submenu: up to 20 recent results, click = copy output, plus Clear.
    private func buildHistorySubmenu() -> NSMenu {
        let submenu = NSMenu()
        let entries = HistoryStore.shared.entries.prefix(20)

        if entries.isEmpty {
            let empty = NSMenuItem(title: "No history yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for entry in entries {
                let preview = entry.output
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespaces)
                let title = "\(preview.prefix(50))\(preview.count > 50 ? "…" : "")"
                let item = NSMenuItem(title: title, action: #selector(copyHistoryEntry(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.output
                item.toolTip = "\(entry.kind.label) — click to copy the result.\n\nInput: \(entry.input.prefix(300))"
                submenu.addItem(item)
            }
            submenu.addItem(.separator())
            let clear = NSMenuItem(title: "Clear History", action: #selector(clearHistory), keyEquivalent: "")
            clear.target = self
            submenu.addItem(clear)
        }
        return submenu
    }

    @objc private func copyHistoryEntry(_ sender: NSMenuItem) {
        guard let output = sender.representedObject as? String else { return }
        TextInjector.copyToPasteboard(output)
    }

    @objc private func clearHistory() {
        HistoryStore.shared.clear()
        rebuildMenu()
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        appState.settings.enabled.toggle()
        rebuildMenu()
    }

    @objc private func grantAccessibility() {
        AccessibilityPermission.requestIfNeeded()
        AccessibilityPermission.openSystemSettings()
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView().environmentObject(appState))
            let window = NSWindow(contentViewController: hosting)
            window.title = "BindAll Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(NSSize(width: 560, height: 558))
            window.center()
            settingsWindow = window
        }
        // An .accessory app cannot reliably bring a window to the front; switch to .regular while
        // the settings window is visible, then revert when it closes (see windowWillClose).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === settingsWindow else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
