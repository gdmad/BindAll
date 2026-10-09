import AppKit
import SwiftUI
import Observation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    let appState = AppState()
    private(set) lazy var coordinator = HotkeyCoordinator(appState: appState)

    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var pulseTimer: Timer?
    /// Alive only while the status menu is open -- see `menuWillOpen`.
    private var menuKeyMonitor: Any?
    private lazy var historyPopover: NSPopover = {
        let popover = NSPopover()
        popover.behavior = .transient
        return popover
    }()
    private var stateObservers: [Task<Void, Never>] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        coordinator.start()
        // Warm up the on-device model so the first action is not paying the cold-start cost.
        AppleFoundationEngine.prewarm()
        prewarmTranslation()
        // Ask for Accessibility up front (needed for the global hotkeys); the system shows its prompt
        // only if not yet granted. No window is opened automatically.
        AccessibilityPermission.requestIfNeeded()

        // The menu-bar icon shows both "processing" (swapped while an action runs) and the master
        // switch (dimmed while off), so it is redrawn whenever either changes.
        let appState = self.appState
        stateObservers.append(Task { [weak self] in
            var last: (busy: Bool, enabled: Bool)?
            for await state in Observations({ (busy: appState.isProcessing, enabled: appState.settings.enabled) }) {
                guard let self else { return }
                if let last, last == state { continue }
                last = state
                self.updateStatusIcon(busy: state.busy)
            }
        })
    }

    func applicationWillTerminate(_ notification: Notification) {
        stateObservers.forEach { $0.cancel() }
        coordinator.stop()
        AutocompleteLearningStore.shared.flush() // save any words learned in the debounce window
    }

    /// The pair does not matter; issuing any status query at launch is what warms the availability
    /// service, so the first real check does not report an installed pack as missing.
    private func prewarmTranslation() {
        let s = appState.settings
        let sourceCode = s.sourceLanguage == AppLanguages.autoTag ? s.targetLanguage : s.sourceLanguage
        TranslationSupport.prewarm(from: Locale.Language(identifier: sourceCode),
                                   to: Locale.Language(identifier: s.targetLanguage))
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

    /// Alpha of the idle icon while the master switch is off. Dimmed rather than a different symbol:
    /// a switched-off app used to look exactly like a working one, which is how it can sit disabled
    /// for days while its shortcuts silently do nothing.
    private static let disabledAlpha: CGFloat = 0.4

    /// The icon is always "sparkles" -- idle, off and busy differ only in alpha, not symbol. It is
    /// the button's own image, so the system click highlight and template inversion work correctly.
    /// While busy, it pulses via the button's alpha (symbol-effect animations would require an
    /// overlay view, which breaks the highlight).
    private func updateStatusIcon(busy: Bool) {
        guard let button = statusItem?.button else { return }
        let enabled = appState.settings.enabled
        let description = busy ? "BindAll — working" : (enabled ? "BindAll" : "BindAll — off")
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        var image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: description)
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
            button.alphaValue = enabled ? 1.0 : Self.disabledAlpha
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

        // Every shortcut hint is drawn by us, in one shared right-aligned column. A burst like Cmd+C+C
        // cannot be expressed as a key equivalent, so those have to be drawn; Settings and Quit are
        // drawn too, on purpose. A real key equivalent makes the system reserve its own column right
        // of the widest title in the menu -- and our drawn line counts as a title -- so it would
        // always sit to the right of ours, and moving ours only moves it further. With no real key
        // equivalents in the menu there is no second column, and all six line up. The two keys still
        // work while the menu is open: see `menuWillOpen`.
        let s = appState.settings
        let leading: [(title: String, shortcut: String, action: Selector)] = [
            ("Fix selection", HotkeyFormatter.string(s.defaultActionHotkey), #selector(menuFix)),
            ("Translate selection", HotkeyFormatter.string(s.translateHotkey), #selector(menuTranslate)),
            ("Translate from screen", HotkeyFormatter.string(s.screenTranslateHotkey), #selector(menuScreenTranslate)),
            ("Quick Translate", HotkeyFormatter.string(s.quickTranslateHotkey), #selector(menuQuickTranslate)),
        ]
        let trailing: [(title: String, shortcut: String, action: Selector)] = [
            ("Settings…", "⌘,", #selector(showSettings)),
            ("Quit BindAll", "⌘Q", #selector(quit)),
        ]
        // Column = widest "title + gap + shortcut" across every shortcut-bearing item.
        let font = NSFont.menuFont(ofSize: 0)
        let gap: CGFloat = 18
        let widths = (leading + trailing)
            .map { (title: $0.title, shortcut: $0.shortcut) }
            .map { (title, shortcut) in
                (title as NSString).size(withAttributes: [.font: font]).width + gap
                    + (shortcut as NSString).size(withAttributes: [.font: font]).width
            }
        let column = ceil(widths.max() ?? 220)

        for a in leading {
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

        for a in trailing {
            menu.addItem(actionMenuItem(a.title, shortcut: a.shortcut, action: a.action, tab: column))
        }
    }

    // MARK: - Keys while the menu is open

    /// The Settings and Quit hints are drawn, not real key equivalents (see `rebuildMenu`), so the two
    /// keys are handled here for as long as the menu is open. Only these two combinations, and only
    /// while the menu is up: outside it they mean nothing to a menu-bar agent with no main menu.
    func menuWillOpen(_ menu: NSMenu) {
        guard menuKeyMonitor == nil else { return }
        menuKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  let action = Self.menuKeyAction(for: event.charactersIgnoringModifiers) else { return event }
            self.statusItem?.menu?.cancelTracking()
            DispatchQueue.main.async { action(self)() }
            return nil
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        if let menuKeyMonitor { NSEvent.removeMonitor(menuKeyMonitor) }
        menuKeyMonitor = nil
    }

    private static func menuKeyAction(for characters: String?) -> ((AppDelegate) -> () -> Void)? {
        switch characters {
        case ",": return { $0.showSettings }
        case "q": return { $0.quit }
        default: return nil
        }
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
            // Sized before the content is attached: a window built around the hosting controller lays
            // the TabView out at zero width first, which AppKit reports as "Invalid view geometry:
            // width is negative" once per tab.
            let size = NSSize(width: 560, height: 558)
            let hosting = NSHostingController(rootView: SettingsView().environment(appState))
            hosting.view.frame = NSRect(origin: .zero, size: size)
            let window = EscClosableWindow(contentRect: NSRect(origin: .zero, size: size),
                                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                           backing: .buffered, defer: false)
            window.contentViewController = hosting
            window.title = "BindAll Settings"
            window.isReleasedWhenClosed = false
            window.delegate = self
            // Remember where the user put it, instead of yanking it back to the center every time.
            if !window.setFrameUsingName(Self.settingsFrameName) { window.center() }
            window.setFrameAutosaveName(Self.settingsFrameName)
            settingsWindow = window
        }
        // An .accessory app cannot reliably bring a window to the front; switch to .regular while
        // the settings window is visible, then revert when it closes (see windowWillClose).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.orderFrontRegardless()
        redirectAppMenuSettingsItem()
    }

    private static let settingsFrameName = "BindAll.settingsWindow"

    /// The app's own menu bar exists only while the activation policy is `.regular`, and its
    /// "Settings…" item points at SwiftUI's `Settings` scene -- a placeholder that exists purely to
    /// satisfy the "an App must have a Scene" requirement and opens an empty window. Point it at the
    /// real settings window instead.
    private func redirectAppMenuSettingsItem() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let appMenu = NSApp.mainMenu?.items.first?.submenu else { return }
            let scenePreferences: Set<Selector> = [Selector(("showSettingsWindow:")),
                                                   Selector(("showPreferencesWindow:"))]
            for item in appMenu.items where item.action.map(scenePreferences.contains) == true {
                item.target = self
                item.action = #selector(self.showSettings)
            }
        }
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
    /// title. It is a hint, not a key equivalent: the real triggers are multi-press bursts that cannot
    /// be represented as one, and the two that could (Settings, Quit) are drawn to keep one column.
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
}

/// A window that closes on Esc (cancelOperation), used for the Settings window.
final class EscClosableWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        performClose(nil)
    }
}
