import AppKit
import Carbon.HIToolbox
import os

/// Word autocomplete. Watches typing with a CGEventTap and suggests completions:
///   - In apps that expose it, the focused field's text + caret are read via the Accessibility API.
///   - Elsewhere (Electron/web), the current word is assembled from the observed keystrokes and the
///     chip is anchored near the mouse.
/// A list of candidates is shown near the caret; Up/Down move the selection and Tab inserts it.
///
/// Threading & latency: an active CGEventTap makes the window server hold every keystroke until the
/// callback returns, which is system-wide input lag. So we run TWO taps on a dedicated background
/// run-loop thread:
///   - `monitorTap` (`.listenOnly`, always on): a passive observer the window server does NOT wait on,
///     so it never delays input. It does the per-key work (unicode decode, word building) and
///     dispatches everything to main.
///   - `suppressTap` (`.defaultTap`, active): enabled ONLY while a suggestion is visible. It consumes
///     the keys that drive the popup (Tab/Return/arrows/Escape) and passes everything else through.
///     While no suggestion is showing it is disabled, so ordinary typing pays no active-tap cost.
/// Created monitor-first, suppressor-second, so the suppressor sits at the head of the tap chain and
/// gets consumable keys before the monitor. All UI/state mutation is on main; the expensive
/// Accessibility + spell-checker work runs on a background `work` queue.
final class AutocompleteController {
    /// Passive observer; never blocks input. Handles ordinary per-key work.
    private var monitorTap: CFMachPort?
    private var monitorSource: CFRunLoopSource?
    /// Active tap that consumes popup-navigation keys; enabled only while a suggestion is visible.
    private var suppressTap: CFMachPort?
    private var suppressSource: CFRunLoopSource?
    /// Tracks the suppressor's enabled state so we only toggle it when `hasSuggestion` actually flips.
    private var suppressorEnabled = false
    /// Dedicated thread whose run loop services the taps, so a busy main thread cannot delay keystrokes.
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?
    private var running = false
    /// Serial queue for the Accessibility queries and NSSpellChecker calls, off the main thread.
    private let work = DispatchQueue(label: "com.bindall.autocomplete.work", qos: .userInitiated)
    private let overlay = AutocompleteOverlay()

    private var debounce: DispatchWorkItem?
    private var appActivationObserver: NSObjectProtocol?
    private var clickMonitor: Any?

    /// Minimal state the tap-thread callback reads to decide whether to consume a key. Written on the
    /// main thread via `syncSuppression()`; read on the tap thread under `suppressionLock`.
    /// The word and the typed partial travel in the snapshot rather than an index: by the time main
    /// runs the accept, a refresh that finished in between may already have replaced `candidates` and
    /// `partial`, and an index would then insert a different word and delete the wrong number of
    /// characters. What the user saw is what gets inserted.
    private struct Suppression {
        var hasSuggestion = false
        var selectedWord = ""
        var partial = ""
        var layout = PopupLayout.column
        var acceptReturn = true
    }
    private var suppression = Suppression()
    private var suppressionLock = os_unfair_lock()

    /// Bumped on every keystroke and on any reset; a refresh computed on `work` is applied only if the
    /// generation still matches when it returns to main (otherwise a newer key has superseded it).
    private var refreshGeneration = 0

    // Current suggestion state.
    private var candidates: [String] = []
    private var selectedIndex = 0
    private var partial = ""
    private var lastAnchor = CGRect.zero

    // Fallback "current word" assembled from keystrokes when AX text is unavailable.
    private var typedBuffer = ""

    // Configurable from Settings.
    enum AppFilterMode: String { case all, allow, deny }
    struct Config {
        var maxSuggestions = 5
        var layout = PopupLayout.column
        var fontSize: CGFloat = 13
        var languages: [String] = []
        var learn = true
        var nextWord = true
        var acceptReturn = true
        var contextRanking = true   // rank completions by the preceding words (the winning variant)
        var appMode = AppFilterMode.all
        var apps: Set<String> = []
    }
    private var config = Config()

    /// The two words completed before the current one (for next-word prediction and n-gram learning).
    private var prevWord = ""
    private var prevWord2 = ""
    private let store = AutocompleteLearningStore.shared

    private let minPrefix = 3

    /// Set while another feature owns the keyboard (a proofread popup is up). Both consume Tab, so
    /// only one may be suggesting at a time. Counted, so overlapping suspend/resume pairs cannot
    /// resume us early.
    private var suspendCount = 0
    private var suspended: Bool { suspendCount > 0 }

    var isRunning: Bool { running }

    // MARK: - Experiment switch

    /// Debug/experiment key in UserDefaults: `baseline` (default), `context` (variant A/B),
    /// `semantic` (variant C). Not exposed in the Settings UI; set with e.g.
    /// `defaults write com.evgeny.bindall AutocompleteVariant -string context`.
    private static let variantKey = "AutocompleteVariant"

    /// The selected ranking mode. A `defaults write` on `AutocompleteVariant` (baseline|context|
    /// semantic) overrides the settings for experiments; otherwise the settings decide: the semantic
    /// mode is experimental and never on by default, context ranking is the default behavior.
    private func rankingMode() -> AutocompleteEngine.Mode {
        if let raw = UserDefaults.standard.string(forKey: Self.variantKey), !raw.isEmpty {
            return AutocompleteEngine.Mode(rawValue: raw) ?? .baseline
        }
        return config.contextRanking ? .context : .baseline
    }

    /// Context scorer for the mode, or nil when the mode does not use one. Called on the work queue
    /// (read-only store access). For the context mode it closes over the two preceding words so the
    /// engine can score each candidate with `store.contextScore`.
    private func contextScorer(mode: AutocompleteEngine.Mode, prev1: String?, prev2: String?) -> ((String) -> Double)? {
        guard mode == .context else { return nil }
        let p1 = prev1, p2 = prev2
        return { [store] word in store.contextScore(word: word, prev1: p1, prev2: p2) }
    }

    /// Semantic scorer for the mode, or nil when the mode does not use one. Called on the work
    /// queue. For the semantic mode it closes over the context words and scores each candidate by
    /// cosine similarity against the context embedding (falls back to 0 when the model is not
    /// ready, which degrades the mode to the pool order).
    private func semanticScorer(mode: AutocompleteEngine.Mode, context: String) -> ((String) -> Double)? {
        guard mode == .semantic, !context.isEmpty else { return nil }
        return { word in SemanticRanker.shared.similarity(context: context, candidate: word) ?? 0 }
    }

    /// Applies user settings.
    func configure(_ config: Config) {
        self.config = config
        syncSuppression()
    }

    /// Hides any suggestion and stops making new ones until `resume()`.
    func suspend() {
        suspendCount += 1
        guard suspendCount == 1 else { return }
        debounce?.cancel()
        resetWord()
    }

    func resume() {
        suspendCount = max(0, suspendCount - 1)
    }

    func start() {
        guard !running, AccessibilityPermission.isGranted else { return }
        // Preload the semantic embedding model (if its assets are available) so the first
        // suggestion in semantic mode is not delayed by model loading.
        SemanticRanker.shared.warmup()
        let mask = (1 << CGEventType.keyDown.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        // Passive monitor: the window server does not wait on a listen-only tap, so it adds no input lag.
        let monitorCallback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<AutocompleteController>.fromOpaque(refcon).takeUnretainedValue()
            return controller.handleMonitor(type: type, event: event)
        }
        guard let monitor = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                              options: .listenOnly, eventsOfInterest: CGEventMask(mask),
                                              callback: monitorCallback, userInfo: userInfo) else { return }

        // Active suppressor: consumes popup-navigation keys. Created after the monitor so it sits at the
        // head of the chain and sees consumable keys first. Enabled only while a suggestion is visible.
        let suppressCallback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<AutocompleteController>.fromOpaque(refcon).takeUnretainedValue()
            return controller.handleSuppress(type: type, event: event)
        }
        guard let suppress = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                               options: .defaultTap, eventsOfInterest: CGEventMask(mask),
                                               callback: suppressCallback, userInfo: userInfo) else { return }

        monitorTap = monitor
        suppressTap = suppress
        let monitorSrc = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, monitor, 0)
        let suppressSrc = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, suppress, 0)
        monitorSource = monitorSrc
        suppressSource = suppressSrc
        suppressorEnabled = false
        running = true
        syncSuppression()

        // Service the taps on their own thread so main-thread work can never delay key delivery. Wait for
        // the thread to install the sources before returning, so tapRunLoop is set for a later stop().
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            let runLoop = CFRunLoopGetCurrent()
            self?.tapRunLoop = runLoop
            CFRunLoopAddSource(runLoop, monitorSrc, .commonModes)
            CFRunLoopAddSource(runLoop, suppressSrc, .commonModes)
            CGEvent.tapEnable(tap: monitor, enable: true)
            CGEvent.tapEnable(tap: suppress, enable: false) // stays off until a suggestion appears
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "com.bindall.autocomplete.tap"
        thread.qualityOfService = .userInteractive
        tapThread = thread
        thread.start()
        ready.wait()

        // Hide the popup the instant focus leaves BindAll's target app, instead of waiting for
        // the next keystroke back in it to notice via appAllowed().
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.resetWord() }
    }

    func stop() {
        guard running else { return }
        running = false
        if let tap = monitorTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let tap = suppressTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoop = tapRunLoop {
            if let source = monitorSource { CFRunLoopRemoveSource(runLoop, source, .commonModes) }
            if let source = suppressSource { CFRunLoopRemoveSource(runLoop, source, .commonModes) }
            CFRunLoopStop(runLoop) // ends CFRunLoopRun so the tap thread exits
        }
        tapRunLoop = nil
        tapThread = nil
        monitorSource = nil
        suppressSource = nil
        monitorTap = nil
        suppressTap = nil
        suppressorEnabled = false
        if let observer = appActivationObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        appActivationObserver = nil
        setClickMonitor(enabled: false)
        debounce?.cancel()
        debounce = nil
        resetWord()
    }

    // MARK: - Event handling

    /// Passive monitor callback (listen-only). Never blocks input: does the per-key unicode decode and
    /// dispatches word-building to main. Keys consumed by the suppressor never reach here.
    private func handleMonitor(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = monitorTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        // Ignore the keystrokes we inject ourselves.
        if InjectedEvents.isInjected(event) { return Unmanaged.passUnretained(event) }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let modified = flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate)
        let typed = unicodeString(from: event)
        DispatchQueue.main.async { [weak self] in self?.onKey(keyCode: keyCode, typed: typed, modified: modified) }
        return Unmanaged.passUnretained(event) // ignored for a listen-only tap
    }

    /// Active suppressor callback. Enabled only while a suggestion is visible. Consumes the keys that
    /// drive the popup and passes everything else through untouched. Kept minimal so the brief window
    /// it is active adds as little latency as possible.
    private func handleSuppress(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Re-arm only if it should currently be active; otherwise leave it off.
            if suppressorEnabled, let tap = suppressTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        if InjectedEvents.isInjected(event) { return Unmanaged.passUnretained(event) }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let modified = flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate)
        let shift = flags.contains(.maskShift)

        // Cheap, lock-protected snapshot of the suggestion state; the real state lives on main.
        let snap = readSuppression()
        guard snap.hasSuggestion, !modified, !shift else { return Unmanaged.passUnretained(event) }

        // Consume the keys that drive the popup — only as bare keys (any modifier, including Shift,
        // passes through, so e.g. Shift+Return still makes a newline).
        let isReturn = keyCode == kVK_Return || keyCode == kVK_ANSI_KeypadEnter
        if keyCode == kVK_Tab || (isReturn && snap.acceptReturn) {
            let word = snap.selectedWord
            let replacing = snap.partial
            invalidateSuppression() // a second fast Tab must not be consumed against the accepted popup
            DispatchQueue.main.async { [weak self] in self?.accept(word: word, replacing: replacing) }
            return nil
        }
        if keyCode == kVK_Escape {
            invalidateSuppression()
            DispatchQueue.main.async { [weak self] in self?.clearSuggestion() }
            return nil
        }
        if let delta = Self.navDelta(for: keyCode, layout: snap.layout) {
            DispatchQueue.main.async { [weak self] in self?.move(dx: delta.dx, dy: delta.dy) }
            return nil
        }
        // Any other key isn't part of the nav set: close the popup now (it touches UI, so on main)
        // instead of waiting for the monitor's onKey boundary handling to catch up, but let the key
        // through so it still reaches the field (and the monitor, which builds the next word).
        // Kill the snapshot synchronously too: a fast Tab right after this key must NOT be consumed
        // and accepted against a stale `partial` (that duplicated the just-typed letter).
        invalidateSuppression()
        DispatchQueue.main.async { [weak self] in self?.clearSuggestion() }
        return Unmanaged.passUnretained(event)
    }

    /// Tap-thread side: marks the suggestion dead immediately, so a key arriving before main has
    /// processed the matching clearSuggestion()/accept() is never matched against stale state. A
    /// later syncSuppression() on main rewrites the snapshot unconditionally, so no re-arm hazard.
    private func invalidateSuppression() {
        os_unfair_lock_lock(&suppressionLock)
        suppression.hasSuggestion = false
        os_unfair_lock_unlock(&suppressionLock)
    }

    /// Reads the tap-thread suppression snapshot under the lock.
    private func readSuppression() -> Suppression {
        os_unfair_lock_lock(&suppressionLock)
        defer { os_unfair_lock_unlock(&suppressionLock) }
        return suppression
    }

    /// Refreshes the tap-thread snapshot from the authoritative main-thread state, and enables the
    /// active suppressor tap exactly while a suggestion is visible. Call on main after any change to
    /// `candidates`, `selectedIndex`, or `config`.
    private func syncSuppression() {
        let hasSuggestion = !candidates.isEmpty
        let snap = Suppression(hasSuggestion: hasSuggestion,
                               selectedWord: candidates.indices.contains(selectedIndex) ? candidates[selectedIndex] : "",
                               partial: partial,
                               layout: config.layout, acceptReturn: config.acceptReturn)
        os_unfair_lock_lock(&suppressionLock)
        suppression = snap
        os_unfair_lock_unlock(&suppressionLock)

        // Toggle the active tap only on an actual transition, so ordinary typing pays no active-tap cost.
        // CGEventTapEnable is safe to call from any thread.
        if hasSuggestion != suppressorEnabled, let tap = suppressTap {
            suppressorEnabled = hasSuggestion
            CGEvent.tapEnable(tap: tap, enable: hasSuggestion)
        }
        setClickMonitor(enabled: running)
    }

    /// The popup ignores mouse events, so a click never reaches it: without this it keeps floating on
    /// top after a click moves the caret away (an app switch is already covered by the observer in
    /// `start()`, but a click inside the same app is not). Passive, so it stays armed the whole time
    /// the feature runs -- a click with no popup up still moves the caret, and leaving `typedBuffer`
    /// and the preceding words behind would build the next suggestion from the word left behind.
    private func setClickMonitor(enabled: Bool) {
        if enabled {
            guard clickMonitor == nil else { return }
            clickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] _ in self?.resetWord() }
        } else if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
    }

    private func onKey(keyCode: Int, typed: String, modified: Bool) {
        // Every keystroke supersedes any refresh still computing on the work queue.
        refreshGeneration &+= 1
        if suspended { return }
        if modified { resetWord(); return }

        // Space completes the current word: learn it and (optionally) predict the next word.
        if keyCode == kVK_Space || typed == " " {
            handleWordBoundary()
            return
        }

        // Return discards the word instead of learning it: it is what submits a password field, and
        // the learning path does not inspect the focused element.
        let navKeys: Set<Int> = [kVK_Escape, kVK_Return, kVK_ANSI_KeypadEnter, kVK_LeftArrow, kVK_RightArrow,
                                 kVK_UpArrow, kVK_DownArrow, kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown]
        if navKeys.contains(keyCode) {
            resetWord()
            return
        }
        if keyCode == kVK_Delete {
            typedBuffer = String(typedBuffer.dropLast())
        } else if typed.count == 1, let scalar = typed.unicodeScalars.first, CharacterSet.letters.contains(scalar) {
            typedBuffer.append(typed)
        } else if typed.count == 1, let c = typed.first, AutocompleteEngine.isWordTerminator(c) {
            // Punctuation completes the word. The space that usually follows drives the next-word
            // prediction, so predicting here would only be premature.
            handleWordBoundary(predictNext: false)
            return
        } else {
            resetWord() // digits, apostrophes, hyphens and other intra-token characters
            return
        }
        scheduleRefresh()
    }

    private func handleWordBoundary(predictNext: Bool = true) {
        let finished = typedBuffer
        if config.learn, !finished.isEmpty {
            store.record(word: finished,
                         prev1: prevWord.isEmpty ? nil : prevWord,
                         prev2: prevWord2.isEmpty ? nil : prevWord2)
        }
        if !finished.isEmpty { prevWord2 = prevWord; prevWord = finished }
        typedBuffer = ""
        clearSuggestion()
        // Whether there is anything to predict from is decided on the work queue, from the field
        // itself where one is available -- not from prevWord, which only knows about the run of
        // typing since the last click or app switch (see nextWordRefresh).
        if predictNext, config.nextWord {
            scheduleRefresh(nextWord: true)
        }
    }

    private func scheduleRefresh(nextWord: Bool = false) {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            if nextWord { self?.nextWordRefresh() } else { self?.refresh() }
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: work)
    }

    // MARK: - Suggestion lifecycle

    /// Runs on main (debounced). Snapshots inputs, then does the Accessibility + spell-checker work on
    /// the `work` queue and applies the result back on main only if no newer keystroke has arrived.
    private func refresh() {
        guard appAllowed() else { resetWord(); return }
        let gen = refreshGeneration
        let cfg = config
        let fallback = typedBuffer
        let primaryHeight = primaryScreenHeight()

        work.async { [weak self] in
            guard let self else { return }
            let resolvedPartial: String
            let resolvedAnchor: CGRect
            // Context for the re-ranking modes: the completed words before the caret. Prefer the AX
            // field text (it is the source of truth for the partial); fall back to the keystroke
            // tracker for apps that expose no text.
            var contextWords: [String] = []
            switch self.focusState() {
            case .secure:
                self.applyOnMain(gen) { $0.resetWord() }
                return
            case .text(let info):
                resolvedPartial = AutocompleteEngine.partialWord(in: info.text, caretUTF16Offset: info.caret)
                resolvedAnchor = self.anchor(for: info.element, caret: info.caret, primaryHeight: primaryHeight)
                contextWords = AutocompleteEngine.precedingWords(in: info.text, caretUTF16Offset: info.caret, count: 2)
            case .unavailable:
                resolvedPartial = fallback
                resolvedAnchor = self.mouseAnchor()
                if !self.prevWord.isEmpty { contextWords.append(self.prevWord) }
                if !self.prevWord2.isEmpty { contextWords.append(self.prevWord2) }
            }

            guard resolvedPartial.count >= self.minPrefix else {
                self.applyOnMain(gen) { $0.clearSuggestion() }
                return
            }
            // The re-ranking modes score a larger candidate pool than the visible list, so ask the
            // store for more learned completions in those modes.
            let mode = self.rankingMode()
            let learnedLimit = mode == .baseline ? cfg.maxSuggestions
                                                 : max(AutocompleteEngine.reRankPoolLimit, cfg.maxSuggestions)
            let learned = cfg.learn ? self.store.completions(matching: resolvedPartial, limit: learnedLimit) : []
            var req = AutocompleteEngine.Request(partial: resolvedPartial, languages: cfg.languages,
                                                 learned: learned, limit: cfg.maxSuggestions, mode: mode)
            req.contextScorer = self.contextScorer(mode: mode,
                                                   prev1: contextWords.first,
                                                   prev2: contextWords.count > 1 ? contextWords[1] : nil)
            req.semanticScorer = self.semanticScorer(mode: mode, context: contextWords.joined(separator: " "))
            let list = AutocompleteEngine.suggestions(request: req)
            self.applyOnMain(gen) { me in
                guard !list.isEmpty else { me.clearSuggestion(); return }
                me.partial = resolvedPartial
                me.typedBuffer = resolvedPartial // keep the fallback buffer in sync with the truth
                me.candidates = list
                me.selectedIndex = 0
                me.lastAnchor = resolvedAnchor
                me.overlay.show(list, selected: 0, layout: cfg.layout, fontSize: cfg.fontSize,
                                anchor: resolvedAnchor)
                me.syncSuppression()
            }
        }
    }

    /// Suggests the next word (with an empty partial) after a space, from the learned bigrams.
    ///
    /// The context comes from the field itself where AX exposes one -- the same source `refresh()`
    /// uses for ranking the current word -- rather than from `prevWord`/`prevWord2`, which only track
    /// the run of typing since the last click, app switch or navigation key. Without this, pausing to
    /// click back into a sentence (or returning from another app) and pressing space produced no
    /// prediction at all, even though the words to predict from were sitting right there in the field.
    private func nextWordRefresh() {
        guard appAllowed(), config.nextWord else { clearSuggestion(); return }
        let gen = refreshGeneration
        let cfg = config
        let fallbackP1 = prevWord
        let fallbackP2 = prevWord2
        let primaryHeight = primaryScreenHeight()

        work.async { [weak self] in
            guard let self else { return }
            let anchor: CGRect
            var p1 = fallbackP1
            var p2 = fallbackP2
            switch self.focusState() {
            case .secure:
                self.applyOnMain(gen) { $0.clearSuggestion() }
                return
            case .text(let info):
                anchor = self.anchor(for: info.element, caret: info.caret, primaryHeight: primaryHeight)
                let words = AutocompleteEngine.precedingWords(in: info.text, caretUTF16Offset: info.caret, count: 2)
                p1 = words.first ?? ""
                p2 = words.count > 1 ? words[1] : ""
            case .unavailable:
                anchor = self.mouseAnchor()
            }
            guard !p1.isEmpty else {
                self.applyOnMain(gen) { $0.clearSuggestion() }
                return
            }
            let words = self.store.nextWords(prev1: p1, prev2: p2.isEmpty ? nil : p2, limit: cfg.maxSuggestions)
            self.applyOnMain(gen) { me in
                guard !words.isEmpty else { me.clearSuggestion(); return }
                me.partial = "" // nothing typed yet, so accept just types the word
                me.candidates = words
                me.selectedIndex = 0
                me.lastAnchor = anchor
                me.overlay.show(words, selected: 0, layout: cfg.layout, fontSize: cfg.fontSize,
                                anchor: anchor)
                me.syncSuppression()
            }
        }
    }

    /// Applies a work-queue result back on the main thread, but only if `gen` is still current (no
    /// newer keystroke has superseded this refresh).
    private func applyOnMain(_ gen: Int, _ body: @escaping (AutocompleteController) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, gen == self.refreshGeneration else { return }
            body(self)
        }
    }

    /// Which arrow keys drive the suggestion selection for a layout, and in which direction. A key a
    /// layout does not navigate with returns nil and falls through to the "user moved on" close path.
    private static func navDelta(for keyCode: Int, layout: PopupLayout) -> (dx: Int, dy: Int)? {
        switch layout {
        case .column:
            switch keyCode {
            case kVK_UpArrow: return (0, -1)
            case kVK_DownArrow: return (0, 1)
            default: return nil
            }
        case .line:
            switch keyCode {
            case kVK_LeftArrow: return (-1, 0)
            case kVK_RightArrow: return (1, 0)
            default: return nil
            }
        case .tile:
            switch keyCode {
            case kVK_UpArrow: return (0, -1)
            case kVK_DownArrow: return (0, 1)
            case kVK_LeftArrow: return (-1, 0)
            case kVK_RightArrow: return (1, 0)
            default: return nil
            }
        }
    }

    private func move(dx: Int, dy: Int) {
        guard !candidates.isEmpty else { return }
        let count = candidates.count
        let next: Int
        switch config.layout {
        case .column: next = max(0, min(count - 1, selectedIndex + dy))
        case .line: next = max(0, min(count - 1, selectedIndex + dx))
        case .tile:
            next = PopupLayout.tileIndex(from: selectedIndex, deltaX: dx, deltaY: dy, count: count,
                                         topRowCount: overlay.lastTileTopCount)
        }
        guard next != selectedIndex else { return }
        selectedIndex = next
        overlay.show(candidates, selected: selectedIndex, layout: config.layout,
                     fontSize: config.fontSize, anchor: lastAnchor)
        syncSuppression()
    }

    /// Inserts `word`, replacing the `partial` the user had typed when the popup showed it.
    private func accept(word: String, replacing current: String) {
        guard !word.isEmpty else { clearSuggestion(); return }
        if config.learn {
            store.record(word: word,
                         prev1: prevWord.isEmpty ? nil : prevWord,
                         prev2: prevWord2.isEmpty ? nil : prevWord2)
        }
        prevWord2 = prevWord
        prevWord = word
        typedBuffer = ""
        clearSuggestion()
        insert(word: word, replacing: current)
    }

    private func clearSuggestion() {
        candidates = []
        selectedIndex = 0
        overlay.hide()
        refreshGeneration &+= 1 // drop any in-flight refresh so it cannot re-show the popup
        syncSuppression()
    }

    private func resetWord() {
        typedBuffer = ""
        partial = ""
        prevWord = ""
        prevWord2 = ""
        clearSuggestion()
    }

    private func appAllowed() -> Bool {
        let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        if bundle == Bundle.main.bundleIdentifier { return false } // never in BindAll's own windows
        switch config.appMode {
        case .all: return true
        case .allow: return config.apps.contains(bundle)
        case .deny: return !config.apps.contains(bundle)
        }
    }

    /// Height of the primary screen (menu-bar screen), captured on the main thread. NSScreen is not
    /// safe to touch from the `work` queue, so callers pass this value down into the anchor math.
    private func primaryScreenHeight() -> CGFloat? {
        (NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main)?.frame.height
    }

    // MARK: - Accessibility

    private struct TextInfo {
        let element: AXUIElement
        let text: String
        let caret: Int
    }

    private enum FocusState {
        case secure
        case text(TextInfo)
        case unavailable
    }

    private func focusState() -> FocusState {
        let system = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let f = focused else { return .unavailable }
        let element = f as! AXUIElement

        // Never autocomplete in a password field.
        var subroleRef: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef) == .success,
           let subrole = subroleRef as? String, subrole == (kAXSecureTextFieldSubrole as String) {
            return .secure
        }

        var valueRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let text = valueRef as? String else { return .unavailable }

        var rangeRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success else {
            return .unavailable
        }
        var range = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range), range.length == 0 else { return .unavailable }

        return .text(TextInfo(element: element, text: text, caret: range.location))
    }

    /// Best anchor for the chip: caret rect, else the focused element's frame, else the mouse. AppKit
    /// screen coordinates -- its height lets the popup rise above it when there is no room below.
    private func anchor(for element: AXUIElement, caret: Int, primaryHeight: CGFloat?) -> CGRect {
        caretAnchor(for: element, caret: caret, primaryHeight: primaryHeight)
            ?? elementFrameAnchor(for: element, primaryHeight: primaryHeight) ?? mouseAnchor()
    }

    /// The focused element's frame (many web/Electron fields expose a frame even when they do not
    /// expose a caret rect). Quartz top-left origin -> AppKit bottom-left, inset the usual 6pt.
    private func elementFrameAnchor(for element: AXUIElement, primaryHeight: CGFloat?) -> CGRect? {
        var posRef: AnyObject?
        var sizeRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success else { return nil }
        var pos = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &pos),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size),
              size.width > 0, size.height > 0 else { return nil }
        let base = primaryHeight ?? (pos.y + size.height)
        let rect = UnderlineGeometry.appKitRect(fromQuartz: CGRect(origin: pos, size: size),
                                                primaryScreenHeight: base)
        return rect.offsetBy(dx: 6, dy: 6)
    }

    /// AppKit rect of the caret, derived from the AX caret rect (Quartz, top-left).
    private func caretAnchor(for element: AXUIElement, caret: Int, primaryHeight: CGFloat?) -> CGRect? {
        var cfRange = CFRange(location: max(0, caret - 1), length: 1)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var boundsRef: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         rangeValue, &boundsRef) == .success else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect), rect.width > 0 || rect.height > 0 else { return nil }
        let base = primaryHeight ?? rect.maxY
        return UnderlineGeometry.appKitRect(fromQuartz: rect, primaryScreenHeight: base)
    }

    private func mouseAnchor() -> CGRect {
        let p = NSEvent.mouseLocation
        return CGRect(x: p.x, y: p.y - 18, width: 1, height: 0)
    }

    // MARK: - Injection

    private func unicodeString(from event: CGEvent) -> String {
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &chars)
        return length > 0 ? String(utf16CodeUnits: chars, count: length) : ""
    }

    /// Replaces the typed partial with the chosen word. Always deletes the partial and types the full
    /// word so the inserted text matches the (recased) suggestion exactly, in every app.
    private func insert(word: String, replacing partial: String) {
        deleteBackward(count: (partial as NSString).length)
        typeString(word)
    }

    private func typeString(_ s: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let utf16 = Array(s.utf16)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return }
        utf16.withUnsafeBufferPointer { buffer in
            down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
        }
        InjectedEvents.mark(down)
        InjectedEvents.mark(up)
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }

    private func deleteBackward(count: Int) {
        guard count > 0 else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        for _ in 0..<count {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: false) else { continue }
            InjectedEvents.mark(down)
            InjectedEvents.mark(up)
            down.post(tap: .cgAnnotatedSessionEventTap)
            up.post(tap: .cgAnnotatedSessionEventTap)
        }
    }
}
