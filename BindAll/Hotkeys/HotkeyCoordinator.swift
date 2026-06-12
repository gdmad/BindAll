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
    private lazy var quickTranslate = QuickTranslateController(appState: appState)

    private var translationWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var retryTimer: Timer?
    private var busyWatchdog: DispatchWorkItem?
    private var isBusy = false

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

        appState.$settings
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.reconfigureWatched()
                self?.refreshStatus()
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
            }
        }
    }

    func stop() {
        retryTimer?.invalidate()
        retryTimer = nil
        monitor.stop()
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
        var watched: [WatchedHotkey] = []
        let configs = [s.defaultActionHotkey, s.translateHotkey, s.screenTranslateHotkey, s.quickTranslateHotkey]
            + s.actionKeys.compactMap(\.hotkey)
        for hk in configs {
            watched.append(WatchedHotkey(keyCode: hk.keyCode, modifiers: hk.modifiers, windowMilliseconds: hk.windowMilliseconds))
        }
        monitor.setWatched(watched)
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
        busyWatchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.isBusy = false
            self?.appState.isProcessing = false
        }
        busyWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: work)
    }

    private func endBusy() {
        busyWatchdog?.cancel()
        busyWatchdog = nil
        isBusy = false
        appState.isProcessing = false
    }

    /// Runs the text pipeline on the current selection. With `fixedInstruction` (a per-key
    /// shortcut) the whole selection is the content; otherwise the separator/key syntax is parsed.
    private func runDefaultAction(fixedInstruction: String? = nil) {
        let settings = appState.settings
        let engine = EngineFactory.make(kind: settings.defaultEngine, appState: appState)
        beginBusy()

        Task { [weak self] in
            guard let self else { return }
            defer { self.endBusy() }

            // The default-action hotkey is Cmd+C-based, so the selection is already on the pasteboard.
            // A per-action-key shortcut (fixedInstruction) does NOT copy, so we copy it ourselves.
            let selection = (fixedInstruction != nil)
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
                if settings.maskAISlop {
                    result = MaskAISlop.apply(to: result)
                }
                self.recordHistory(kind: .action, input: parsed.content, output: result,
                                   engine: settings.defaultEngine.displayName)
                TextInjector.replaceSelection(with: result, restorePrevious: settings.restoreClipboard)
            } catch {
                self.popup.show(title: "Error", text: error.localizedDescription)
            }
        }
    }

    private func runTranslate() {
        beginBusy()
        Task { [weak self] in
            guard let self else { return }
            defer { self.endBusy() }

            guard let text = SelectionReader.currentSelection(previousChangeCount: Int.min),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.popup.show(title: "BindAll", text: "No text selected.")
                return
            }
            await self.translateAndShow(text, historyKind: .translate)
        }
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

        let sourceConcrete = from ?? Locale.Language(identifier: "en")
        guard await TranslationSupport.isInstalled(from: sourceConcrete, to: target) else {
            popup.show(
                title: "Translation",
                text: "\(sourceDisplay) -> \(AppLanguages.name(for: targetCode)) is not downloaded yet. Open System Settings > General > Language & Region > Translation Languages to download it, then try again."
            )
            return
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
