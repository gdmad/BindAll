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
    private lazy var historyPopover: NSPopover = {
        let popover = NSPopover()
        popover.behavior = .transient
        return popover
    }()
    private var cancellables = Set<AnyCancellable>()

    /// SF Symbol shown when idle.
    private let idleSymbol = "text.cursor"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        coordinator.start()
        // Warm up the on-device model so the first action is not paying the cold-start cost.
        AppleFoundationEngine.prewarm()
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

        menu.addItem(.separator())

        // The same actions the global shortcuts trigger, plus Settings/Quit, all drawn with their
        // shortcut in one shared right-aligned column. Settings/Quit use custom titles (not native
        // key equivalents) so they share the column and the menu has no stray space on the right.
        let s = appState.settings
        var actions: [(title: String, shortcut: String, action: Selector)] = [
            ("Fix selection", HotkeyFormatter.string(s.defaultActionHotkey), #selector(menuFix)),
            ("Translate selection", HotkeyFormatter.string(s.translateHotkey), #selector(menuTranslate)),
            ("Translate from screen", HotkeyFormatter.string(s.screenTranslateHotkey), #selector(menuScreenTranslate)),
            ("Quick Translate", HotkeyFormatter.string(s.quickTranslateHotkey), #selector(menuQuickTranslate)),
        ]
        if s.correctEnabled {
            actions.append(("Correct (LanguageTool)", HotkeyFormatter.string(s.correctHotkey), #selector(menuCorrect)))
        }

        // Column = widest "title + gap + shortcut" across every shortcut-bearing item.
        let font = NSFont.menuFont(ofSize: 0)
        let gap: CGFloat = 18
        let widths = (actions.map { ($0.title, $0.shortcut) } + [("Settings…", "⌘,"), ("Quit BindAll", "⌘Q")])
            .map { (title, shortcut) in
                (title as NSString).size(withAttributes: [.font: font]).width + gap
                    + (shortcut as NSString).size(withAttributes: [.font: font]).width
            }
        let column = ceil(widths.max() ?? 220)

        for a in actions {
            menu.addItem(actionMenuItem(a.title, shortcut: a.shortcut, action: a.action, tab: column))
        }

        menu.addItem(.separator())

        if appState.settings.historyEnabled {
            // A plain item (not a submenu) so the menu reserves no submenu-arrow column. It opens a
            // floating panel instead.
            let history = NSMenuItem(title: "History…", action: #selector(showHistory), keyEquivalent: "")
            history.target = self
            menu.addItem(history)
        }

        menu.addItem(actionMenuItem("Settings…", shortcut: "⌘,", action: #selector(showSettings), tab: column))
        menu.addItem(actionMenuItem("Quit BindAll", shortcut: "⌘Q", action: #selector(quit), tab: column))
    }

    /// Shows the History panel as a popover anchored to the status item.
    @objc private func showHistory() {
        guard let button = statusItem?.button else { return }
        let view = HistoryPanelView(
            entries: HistoryStore.shared.entries,
            onCopy: { [weak self] text in
                TextInjector.copyToPasteboard(text)
                self?.historyPopover.performClose(nil)
            },
            onClear: { [weak self] in
                HistoryStore.shared.clear()
                self?.historyPopover.performClose(nil)
            }
        )
        historyPopover.contentViewController = NSHostingController(rootView: view)
        // Activate so the popover is interactive (we are an accessory app).
        NSApp.activate(ignoringOtherApps: true)
        historyPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
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
            let window = EscClosableWindow(contentViewController: hosting)
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

    // MARK: - Action menu items

    private func actionMenuItem(_ title: String, shortcut: String, action: Selector, tab: CGFloat) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.attributedTitle = Self.menuTitle(title, shortcut: shortcut, tab: tab)
        return item
    }

    /// Title with the shortcut in a secondary color, aligned to a `tab` column just past the widest
    /// title. It is a non-functional hint: the real triggers are multi-press bursts that cannot be
    /// represented as NSMenuItem key equivalents.
    private static func menuTitle(_ title: String, shortcut: String, tab: CGFloat) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: tab)]
        paragraph.lineBreakMode = .byClipping
        let string = NSMutableAttributedString(string: "\(title)\t\(shortcut)")
        string.addAttributes([.font: NSFont.menuFont(ofSize: 0),
                              .paragraphStyle: paragraph],
                             range: NSRange(location: 0, length: string.length))
        let shortcutStart = (title as NSString).length + 1
        string.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor,
                            range: NSRange(location: shortcutStart, length: (shortcut as NSString).length))
        return string
    }

    @objc private func menuFix() { coordinator.menuFix() }
    @objc private func menuTranslate() { coordinator.menuTranslate() }
    @objc private func menuScreenTranslate() { coordinator.menuScreenTranslate() }
    @objc private func menuQuickTranslate() { coordinator.menuQuickTranslate() }
    @objc private func menuCorrect() { coordinator.menuCorrect() }
}

/// A window that closes on Esc (cancelOperation), used for the Settings window.
final class EscClosableWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        performClose(nil)
    }
}
