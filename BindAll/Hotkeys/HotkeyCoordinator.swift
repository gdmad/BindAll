import AppKit
import SwiftUI
import Combine

/// Wires global hotkeys to the selection → engine/translation pipeline.
@MainActor
final class HotkeyCoordinator: ObservableObject {
    private let appState: AppState
    private let monitor = HotkeyMonitor()
    private let translationCoordinator = TranslationCoordinator()
    private let popup = PopupController()
    private let autocomplete = AutocompleteController()
    private lazy var quickTranslate = QuickTranslateController(appState: appState)

    private var translationWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var retryTimer: Timer?
    private var busyWatchdog: DispatchWorkItem?
    private var isBusy = false

    // The in-flight engine task and the Esc monitors that can cancel it.
    private var currentTask: Task<Void, Never>?
    private var escGlobalMonitor: Any?
    private var escLocalMonitor: Any?

    init(appState: AppState) {
        self.appState = appState
    }

    func start() {
        AccessibilityPermission.requestIfNeeded()
        refreshStatus()
        setupTranslationWindow()

        monitor.onBurst = { [weak self] keyCode, mods, count in
            self?.handleBurst(keyCode: keyCode, modifiers: mods, count: count)
        }
        reconfigureWatched()
        _ = monitor.start()
        updateAutocomplete()

        appState.$settings
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.reconfigureWatched()
                self?.refreshStatus()
                self?.updateAutocomplete()
            }
            .store(in: &cancellables)

        // The event tap can only be installed once Accessibility is granted. Poll so the user does
        // not have to relaunch after granting permission, and keep the status indicators live.
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshStatus()
                if !self.monitor.isRunning, AccessibilityPermission.isGranted {
                    self.reconfigureWatched()
                    _ = self.monitor.start()
                }
                self.updateAutocomplete()
            }
        }
    }

    /// Starts or stops the experimental autocomplete depending on the setting and Accessibility.
    private func updateAutocomplete() {
        let s = appState.settings
        var cfg = AutocompleteController.Config()
        cfg.maxSuggestions = s.autocompleteCount
        cfg.horizontal = s.autocompleteHorizontal
        cfg.fontSize = CGFloat(max(10, min(20, s.autocompleteFontSize)))
        cfg.languages = s.autocompleteLanguages
        cfg.learn = s.autocompleteLearn
        cfg.nextWord = s.autocompleteNextWord
        cfg.acceptReturn = s.autocompleteAcceptReturn
        cfg.appMode = AutocompleteController.AppFilterMode(rawValue: s.autocompleteAppMode) ?? .all
        cfg.apps = Set(s.autocompleteApps)
        autocomplete.configure(cfg)
        if appState.settings.autocompleteEnabled, AccessibilityPermission.isGranted {
            autocomplete.start()
        } else {
            autocomplete.stop()
        }
    }

    func stop() {
        retryTimer?.invalidate()
        retryTimer = nil
        monitor.stop()
        autocomplete.stop()
        popup.close()
        translationWindow?.orderOut(nil)
    }

    func refreshStatus() {
        appState.accessibilityGranted = AccessibilityPermission.isGranted
        appState.appleEngineStatus = AppleFoundationEngine.availabilityStatus().message
    }

    // MARK: - Setup

    private func setupTranslationWindow() {
        guard translationWindow == nil else { return }
        let host = NSHostingController(rootView: TranslationHostView(coordinator: translationCoordinator))
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.borderless]
        // Keep it a 1x1, fully transparent window placed at a NORMAL on-screen coordinate. Putting it
        // at extreme offscreen coordinates makes Mission Control zoom out to fit it (shrinking every
        // other window). Excluding it from cycling/Mission Control keeps it out of the way.
        let origin = NSScreen.main?.frame.origin ?? .zero
        window.setFrame(NSRect(x: origin.x, y: origin.y, width: 1, height: 1), display: false)
        window.alphaValue = 0.0
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenAuxiliary, .canJoinAllSpaces]
        window.level = .normal
        window.orderBack(nil)
        translationWindow = window
    }

    private func reconfigureWatched() {
        let s = appState.settings
        var configs = [s.defaultActionHotkey, s.translateHotkey, s.screenTranslateHotkey, s.quickTranslateHotkey]
            + s.actionKeys.compactMap(\.hotkey)
        if s.correctEnabled { configs.append(s.correctHotkey) }

        // Group configs that share key+modifiers so the monitor knows the highest press count to
        // expect for that key and can fire immediately once it is reached.
        var grouped: [String: WatchedHotkey] = [:]
        for hk in configs {
            let m = hk.modifiers
            let key = "\(hk.keyCode)|\(m.command)\(m.option)\(m.control)\(m.shift)"
            if var existing = grouped[key] {
                existing.maxRepeat = max(existing.maxRepeat, hk.repeatCount)
                grouped[key] = existing
            } else {
                grouped[key] = WatchedHotkey(keyCode: hk.keyCode, modifiers: m, maxRepeat: hk.repeatCount)
            }
        }
        monitor.setWatched(Array(grouped.values))
    }

    // MARK: - Burst handling

    private func handleBurst(keyCode: UInt16, modifiers: HotkeyModifiers, count: Int) {
        let s = appState.settings
        guard s.enabled, !appState.isRecordingShortcut else { return }

        func matches(_ h: HotkeyConfig) -> Bool {
            h.keyCode == keyCode && h.modifiers == modifiers && h.repeatCount == count
        }

        // Quick Translate opens an interactive window; it does not need a selection and is allowed
        // even while another action is in flight.
        if matches(s.quickTranslateHotkey) {
            quickTranslate.toggle()
            return
        }

        guard !isBusy else { return }

        if matches(s.defaultActionHotkey) {
            runDefaultAction()
        } else if matches(s.translateHotkey) {
            runTranslate()
        } else if matches(s.screenTranslateHotkey) {
            translateFromScreen()
        } else if s.correctEnabled, matches(s.correctHotkey) {
            runCorrect()
        } else if let key = s.actionKeys.first(where: { $0.hotkey.map(matches) == true }) {
            // A custom action key bound to its own shortcut: run its prompt on the selection.
            runDefaultAction(fixedInstruction: key.prompt)
        }
    }

    /// Marks the coordinator busy and schedules a watchdog so a stalled operation can never
    /// permanently block future hotkeys.
    private func beginBusy() {
        isBusy = true
        appState.isProcessing = true
        installEscMonitor()
        busyWatchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.isBusy = false
            self?.appState.isProcessing = false
            self?.removeEscMonitor()
        }
        busyWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: work)
    }

    private func endBusy() {
        busyWatchdog?.cancel()
        busyWatchdog = nil
        isBusy = false
        appState.isProcessing = false
        currentTask = nil
        removeEscMonitor()
    }

    // MARK: - Esc cancellation

    /// While busy, Esc (key code 53) cancels the in-flight engine task. A global monitor catches it
    /// when another app has focus (the usual case); a local monitor catches it in our own windows.
    private func installEscMonitor() {
        guard escGlobalMonitor == nil, escLocalMonitor == nil else { return }
        escGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.currentTask?.cancel() }
        }
        escLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.currentTask?.cancel(); return nil }
            return event
        }
    }

    private func removeEscMonitor() {
        if let m = escGlobalMonitor { NSEvent.removeMonitor(m); escGlobalMonitor = nil }
        if let m = escLocalMonitor { NSEvent.removeMonitor(m); escLocalMonitor = nil }
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    /// Runs the text pipeline on the current selection. With `fixedInstruction` (a per-key
    /// shortcut) the whole selection is the content; otherwise the separator/key syntax is parsed.
    private func runDefaultAction(fixedInstruction: String? = nil, forceCopy: Bool = false) {
        let settings = appState.settings
        let engine = EngineFactory.make(kind: settings.defaultEngine, appState: appState)
        beginBusy()
        // Capture where the result must land before the (possibly slow) engine call.
        let target = TextInjector.FocusTarget.capture()

        currentTask = Task { [weak self] in
            guard let self else { return }
            defer { self.endBusy() }

            // The default-action hotkey is Cmd+C-based, so the selection is already on the pasteboard.
            // A per-action-key shortcut (fixedInstruction) or a menu invocation (forceCopy) does NOT
            // copy, so we copy it ourselves.
            let selection = (fixedInstruction != nil || forceCopy)
                ? SelectionReader.copyCurrentSelection()
                : SelectionReader.currentSelection(previousChangeCount: Int.min)

            guard let text = selection,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.popup.show(title: "BindAll", text: "No text selected.")
                return
            }

            let parsed: ParsedAction
            if let fixedInstruction {
                parsed = ParsedAction(
                    content: text.trimmingCharacters(in: .whitespacesAndNewlines),
                    instruction: fixedInstruction,
                    hadExplicitInstruction: true
                )
            } else {
                parsed = PromptParser.parse(
                    text: text,
                    separator: settings.separator,
                    defaultPrompt: settings.defaultPrompt,
                    actionKeys: settings.actionKeys
                )
            }

            do {
                var result = try await engine.process(text: parsed.content, instruction: parsed.instruction)
                if Task.isCancelled { return }
                if settings.maskAISlop {
                    result = MaskAISlop.apply(to: result)
                }
                self.recordHistory(kind: .action, input: parsed.content, output: result,
                                   engine: settings.defaultEngine.displayName)
                TextInjector.replaceSelection(with: result, restorePrevious: settings.restoreClipboard, target: target)
            } catch {
                if self.isCancellation(error) { return }
                self.popup.show(title: "Error", text: error.localizedDescription)
            }
        }
    }

    /// Runs the LanguageTool "Correct" action on the current selection. The Correct shortcut is not a
    /// copy shortcut, so the selection is copied first; the result is written back in place.
    private func runCorrect() {
        let settings = appState.settings
        let engine = EngineFactory.makeLanguageTool(appState: appState)
        beginBusy()
        let target = TextInjector.FocusTarget.capture()

        currentTask = Task { [weak self] in
            guard let self else { return }
            defer { self.endBusy() }

            guard let text = SelectionReader.copyCurrentSelection(),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.popup.show(title: "BindAll", text: "No text selected.")
                return
            }

            do {
                var result = try await engine.correct(text)
                if Task.isCancelled { return }
                if settings.maskAISlop {
                    result = MaskAISlop.apply(to: result)
                }
                self.recordHistory(kind: .action, input: text, output: result, engine: "LanguageTool")
                TextInjector.replaceSelection(with: result, restorePrevious: settings.restoreClipboard, target: target)
            } catch {
                if self.isCancellation(error) { return }
                self.popup.show(title: "Correct", text: error.localizedDescription)
            }
        }
    }

    private func runTranslate(forceCopy: Bool = false) {
        beginBusy()
        Task { [weak self] in
            guard let self else { return }
            defer { self.endBusy() }

            let selection = forceCopy
                ? SelectionReader.copyCurrentSelection()
                : SelectionReader.currentSelection(previousChangeCount: Int.min)
            guard let text = selection,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.popup.show(title: "BindAll", text: "No text selected.")
                return
            }
            await self.translateAndShow(text, historyKind: .translate)
        }
    }

    // MARK: - Menu entry points

    /// Invoked from the status menu. Runs after a short delay so the menu fully dismisses and focus
    /// returns to the previously active app before the selection is copied.
    func menuFix() { runFromMenu { self.runDefaultAction(forceCopy: true) } }
    func menuTranslate() { runFromMenu { self.runTranslate(forceCopy: true) } }
    func menuCorrect() { runFromMenu { self.runCorrect() } }
    func menuScreenTranslate() { translateFromScreen() }
    func menuQuickTranslate() { quickTranslate.toggle() }

    private func runFromMenu(_ action: @escaping () -> Void) {
        guard appState.settings.enabled, !isBusy else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: action)
    }

    /// Captures a screen region, OCRs it, then translates the recognized text. Triggered from the menu.
    func translateFromScreen() {
        guard !isBusy else { return }
        beginBusy()
        Task { [weak self] in
            guard let self else { return }
            defer { self.endBusy() }
            do {
                let text = try await OCRService.captureAndRecognize()
                await self.translateAndShow(text, historyKind: .ocr)
            } catch {
                self.popup.show(title: "OCR", text: error.localizedDescription)
            }
        }
    }

    /// Records a successful operation in history (if enabled in settings).
    func recordHistory(kind: HistoryEntry.Kind, input: String, output: String, engine: String) {
        guard appState.settings.historyEnabled else { return }
        HistoryStore.shared.record(kind: kind, input: input, output: output, engine: engine)
    }

    /// Shared translation + popup, using the configured two-language pair.
    private func translateAndShow(_ text: String, historyKind: HistoryEntry.Kind) async {
        let settings = appState.settings
        let detected = LanguageDetector.detect(text)
        let detectedCode = detected?.languageCode?.identifier
        let sourceSetting = settings.sourceLanguage
        let from: Locale.Language?
        let targetCode: String
        if sourceSetting == AppLanguages.autoTag {
            // Auto-detect the source; translate into the configured target.
            from = detected
            targetCode = settings.targetLanguage
        } else {
            // Explicit source: bidirectional pair {source, target}.
            from = detected ?? Locale.Language(identifier: sourceSetting)
            targetCode = (detectedCode == sourceSetting) ? settings.targetLanguage : sourceSetting
        }
        let target = Locale.Language(identifier: targetCode)
        let sourceDisplay = detectedCode.map { AppLanguages.name(for: $0) } ?? AppLanguages.name(for: sourceSetting)

        // Nothing to translate when the text is already in the target language. This is the common
        // false trigger for the download prompt when the source is auto-detected.
        if let detectedCode, detectedCode == targetCode {
            popup.show(title: "Translation",
                       text: "This text is already in \(AppLanguages.name(for: targetCode)).")
            return
        }

        // Only block on a missing language pack when the source is actually known and differs from
        // the target (checking both directions, since a pack installed one way covers both). With an
        // unknown source, let the Translation framework auto-detect and surface any real problem
        // itself, rather than guessing a source and prompting to download something already present.
        if let from, from.languageCode?.identifier != targetCode {
            let forward = await TranslationSupport.isInstalled(from: from, to: target)
            let backward = await TranslationSupport.isInstalled(from: target, to: from)
            if !forward && !backward {
                popup.show(
                    title: "Translation",
                    text: "\(sourceDisplay) -> \(AppLanguages.name(for: targetCode)) is not downloaded yet. Open System Settings > General > Language & Region > Translation Languages to download it, then try again."
                )
                return
            }
        }

        do {
            let translation = try await translationCoordinator.translate(text, from: from, to: target)
            recordHistory(kind: historyKind, input: text, output: translation, engine: "Apple Translation")
            popup.show(title: "", text: translation, original: text, sourceLanguage: sourceDisplay)
        } catch {
            popup.show(title: "Translation failed", text: error.localizedDescription)
        }
    }
}
