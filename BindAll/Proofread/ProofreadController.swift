import AppKit
import Carbon.HIToolbox
import os

/// Steps the user through the issues LanguageTool found in the focused field, one at a time.
///
/// Two ways in:
///   - the Proofread shortcut checks the whole field and starts at the first issue;
///   - a single click inside a problem word pops the fixes for it up on its own.
/// Either way the current issue is selected in the user's own field (`kAXSelectedTextRange`), so the
/// highlight is drawn natively by the app and we never paint over anyone's text.
///
/// Threading: an active `CGEventTap` is only alive while the popup is showing, and its callback does
/// nothing but read a lock-protected snapshot and hand the key to main. See `AutocompleteController`
/// for why that matters -- an active tap makes the window server wait on us for every keystroke.
@MainActor
final class ProofreadController {
    enum AppFilterMode: String { case all, allow, deny }

    struct Config {
        var enabled = false
        var autoOnClick = true
        var maxReplacements = 3
        var minLength = 12
        var restoreClipboard = false
        var appMode = AppFilterMode.all
        var apps: Set<String> = []
    }

    private var config = Config()
    private var provider: LanguageToolProofreadProvider?
    private let popover = ProofreadPopover()
    private let underlines = UnderlineOverlay()

    // Live state: what was found in the focused field. Outlives the popup -- the underlines stay up
    // while the user reads, and a click can open the fixes without another round trip.
    private var target: ProofTarget?
    private var issues: [TextIssue] = []
    /// The field text the current `issues` were found in; a re-check is pointless while it matches.
    private var lastCheckedText = ""
    // Navigation state: which issue the popup is on.
    private var currentIndex = 0
    private var selectedReplacement = 0
    private var checkTask: Task<Void, Never>?
    /// Bumped on every new check and on end(); a result that comes back stale is dropped.
    private var generation = 0

    /// Typing pause that triggers a live re-check.
    private let typingPause: TimeInterval = 0.6
    private var keyMonitor: Any?
    private var typingDebounce: DispatchWorkItem?

    /// The last server error, so live checking reports it once instead of on every pause.
    private var lastError: String?
    /// True while a fix is being applied (the applier waits for the app's selection to settle).
    private var isApplying = false

    /// For the diagnostics report.
    var liveIssueCount: Int { issues.count }
    var lastCheckError: String? { lastError }

    // Key interception, alive only while the popup is up.
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var tapEnabled = false
    /// The one piece of state the tap callback reads. It lives outside the main actor because the
    /// callback runs on the tap thread and must decide without hopping or blocking.
    private let shared = SharedState()

    /// Written on main, read on the tap thread, guarded by its own lock.
    private final class SharedState: @unchecked Sendable {
        private var lock = os_unfair_lock()
        private var value = false

        var isActive: Bool {
            get {
                os_unfair_lock_lock(&lock)
                defer { os_unfair_lock_unlock(&lock) }
                return value
            }
            set {
                os_unfair_lock_lock(&lock)
                value = newValue
                os_unfair_lock_unlock(&lock)
            }
        }
    }

    // Auto-popup on click.
    private var mouseMonitor: Any?
    private var appSwitchObserver: NSObjectProtocol?
    private var clickDebounce: DispatchWorkItem?
    /// A double-click/drag selection longer than this is the user copying text, not fixing a word.
    private let maxAutoSelection = 40

    /// Set by the coordinator so a proofread session can silence autocomplete: both features eat Tab.
    var onSessionChange: ((Bool) -> Void)?

    var isSessionActive: Bool { !issues.isEmpty && target != nil }

    // MARK: - Lifecycle

    func configure(_ config: Config, engine: LanguageToolEngine, language: String) {
        self.config = config
        let provider = self.provider ?? LanguageToolProofreadProvider(engine: engine, language: language)
        self.provider = provider
        Task { await provider.configure(engine: engine, language: language) }

        if config.enabled && config.autoOnClick {
            startClickMonitor()
        } else {
            stopClickMonitor()
        }
        if config.enabled {
            startTypingMonitor()
        } else {
            stopTypingMonitor()
            end()
        }
    }

    func stop() {
        end()
        stopClickMonitor()
        stopTypingMonitor()
    }

    // MARK: - Entry points
    //
    // There is no shortcut: checking happens on its own after a pause in typing, and the fixes are
    // opened by clicking a underlined word. Tab still moves to the next issue while the popup is up.

    /// Mouse-up: show the fixes for the clicked word. When the live pass already checked this text
    /// the popup opens instantly; otherwise the click doubles as a check request.
    private func clickedInText() {
        guard config.enabled, config.autoOnClick, AccessibilityPermission.isGranted, appAllowed() else { return }
        guard case .axField(let found) = ProofreadAX.focus() else { return }
        guard found.text.trimmingCharacters(in: .whitespacesAndNewlines).count >= config.minLength else { return }

        var probe: NSRange
        if found.selection.length > 0 {
            // Double-click or drag: reuse the selection when it is word-sized; a long selection is
            // the user copying text, so stay quiet.
            guard found.selection.length <= maxAutoSelection else { return }
            probe = found.selection
        } else if let word = WordBoundary.wordRange(at: found.caret, in: found.text) {
            probe = word
            // The caret comes from the app's selection, which in Chromium is indexed differently
            // from the value we measured the word in. Translate it back into our offsets, so the
            // popup belongs to the word actually clicked.
            let clicked = (found.text as NSString).substring(with: word)
            if let appRange = ProofreadAX.alignedRange(word, expecting: clicked, in: found.element),
               appRange != word,
               let ourRange = WordBoundary.wordRange(at: word.location - (appRange.location - word.location),
                                                     in: found.text) {
                probe = ourRange
            }
        } else {
            // Clicked whitespace or an empty spot: close the popup but keep the underlines.
            endNavigation()
            return
        }

        let sameField = target?.element == found.element
        target = found
        if sameField, found.text == lastCheckedText {
            showFixes(overlapping: probe) // already known: no round trip
            return
        }
        check(text: found.text, offset: 0, selection: probe)
    }

    /// Typing paused: re-check the focused field so the underlines match what is on screen now.
    private func typingPaused() {
        guard config.enabled, AccessibilityPermission.isGranted, appAllowed() else { return }
        guard case .axField(let found) = ProofreadAX.focus() else { clearLive(); return }
        guard found.text.trimmingCharacters(in: .whitespacesAndNewlines).count >= config.minLength else {
            clearLive()
            return
        }

        let sameField = target?.element == found.element
        target = found
        if sameField, found.text == lastCheckedText {
            // Nothing changed (arrow keys, modifiers): just put the underlines back.
            redrawUnderlines()
            return
        }
        if !sameField { issues = [] }
        // Paragraph cache keeps this to one request for the paragraph actually edited.
        check(text: found.text, offset: 0)
    }

    // MARK: - Checking

    /// Checks `text`; `selection`, when given, is the word the user clicked and decides whether the
    /// fixes pop up afterwards. Checking is always in the background now, so nothing is shown while
    /// it runs -- only a server error the user has not seen yet.
    private func check(text: String, offset: Int, selection: NSRange? = nil) {
        guard let provider else { return }
        generation &+= 1
        let gen = generation
        checkTask?.cancel()

        checkTask = Task { [weak self] in
            guard let self else { return }
            do {
                let found = try await provider.check(text)
                guard !Task.isCancelled, gen == self.generation else { return }
                let rebased = offset == 0 ? found : ProofreadCache.rebase(found, to: offset)
                self.lastError = nil
                self.applyResults(rebased, selection: selection)
            } catch {
                guard !Task.isCancelled, gen == self.generation else { return }
                // Live checking runs unprompted, so report a problem once rather than on every pause.
                let message = Self.describe(error)
                if message != self.lastError {
                    self.lastError = message
                    self.flash(message)
                }
            }
        }
    }

    private func applyResults(_ found: [TextIssue], selection: NSRange?) {
        // Cap once at the door so the popup, arrow navigation and accept all see the same list.
        issues = IssueMerger.capReplacements(found, limit: config.maxReplacements)
        lastCheckedText = target?.text ?? ""
        redrawUnderlines()

        // The popup only opens for a clicked word that sits on an issue.
        guard let selection else { return }
        showFixes(overlapping: selection)
    }

    /// Opens the popup for the issue under `probe`, if there is one. Keeps the underlines either way.
    private func showFixes(overlapping probe: NSRange) {
        guard let issue = IssueMerger.firstIssue(in: issues, overlapping: probe),
              let index = issues.firstIndex(where: { $0.id == issue.id }) else {
            endNavigation()
            return
        }
        // Select the issue natively (like the shortcut path) so the user sees exactly what will be
        // replaced before accepting. Safe re-entrancy: the click monitor reacts only to real
        // mouse-ups, and an AX selection write generates none.
        focusIssue(index)
    }

    private func redrawUnderlines() {
        guard !issues.isEmpty, let element = target?.element else {
            underlines.hide()
            return
        }
        underlines.show(issues: issues, element: element)
    }

    // MARK: - Session

    private func focusIssue(_ index: Int) {
        guard index >= 0, index < issues.count else { endNavigation(); return }
        currentIndex = index
        selectedReplacement = 0
        showCurrent(select: true)
        setActive(true)
    }

    /// Shows the popup for the current issue. `select` also highlights it in the user's field.
    private func showCurrent(select: Bool) {
        guard currentIndex < issues.count else { endNavigation(); return }
        let issue = issues[currentIndex]

        if select, let element = target?.element {
            ProofreadAX.select(issue.range, in: element)
        }
        popover.show(issue: issue, selected: selectedReplacement,
                     position: "\(currentIndex + 1) of \(issues.count)",
                     topLeft: anchor(for: issue),
                     onHover: { [weak self] index in self?.hoverReplacement(index) },
                     onAccept: { [weak self] index in self?.acceptReplacement(index) })
    }

    /// Mouse hover over a row: mirror it into the keyboard selection.
    private func hoverReplacement(_ index: Int) {
        guard let issue = issues[safe: currentIndex], index >= 0, index < issue.replacements.count,
              index != selectedReplacement else { return }
        selectedReplacement = index
        showCurrent(select: false)
    }

    /// Mouse click on a row: same path as selecting it with arrows and pressing Return.
    private func acceptReplacement(_ index: Int) {
        guard let issue = issues[safe: currentIndex], index >= 0, index < issue.replacements.count else { return }
        selectedReplacement = index
        accept()
    }

    private func move(_ delta: Int) {
        let issue = issues[safe: currentIndex]
        guard let count = issue?.replacements.count, count > 0 else { return }
        selectedReplacement = max(0, min(count - 1, selectedReplacement + delta))
        showCurrent(select: false)
    }

    private func skip() {
        guard currentIndex + 1 < issues.count else { endNavigation(); return }
        focusIssue(currentIndex + 1)
    }

    private func accept() {
        guard !isApplying else { return } // applying waits for the selection to settle; ignore repeats
        guard let issue = issues[safe: currentIndex],
              let replacement = issue.replacements[safe: selectedReplacement] else { skip(); return }
        guard let target else {
            // No AX element: the best we can do is hand them the corrected word.
            TextInjector.copyToPasteboard(replacement)
            flash("This app does not expose its text; \"\(replacement)\" is on the clipboard.")
            return
        }

        isApplying = true
        Task { @MainActor [weak self] in
            let result = await IssueApplier.apply(issue, replacement: replacement,
                                                  element: target.element, pid: target.pid,
                                                  restoreClipboard: self?.config.restoreClipboard ?? false)
            guard let self else { return }
            self.isApplying = false
            self.handleApplyResult(result, issue: issue, replacement: replacement)
        }
    }

    private func handleApplyResult(_ result: IssueApplier.Result, issue: TextIssue, replacement: String) {
        switch result {
        case .applied(let replacedRange):
            // Slide the remaining ranges so the underlines move with the text right away.
            issues = IssueMerger.shift(issues, replacedRange: replacedRange,
                                       replacementUTF16Length: (replacement as NSString).length)
            // The popup closes: stepping straight to the next issue would work off ranges that are
            // only a guess until the write actually lands (the paste path is asynchronous), which is
            // how the following fix ended up refusing or hitting the wrong word.
            endNavigation()
            underlines.hide()
            recheckAfterWrite(previousText: lastCheckedText)
        case .stale:
            // Force the next pause to re-check: what we knew about the field no longer holds.
            lastCheckedText = ""
            flash("The text changed - checking again…")
        case .failed(let reason):
            flash(reason)
        }
    }

    /// Waits for the applied fix to actually show up in the field (Chromium pastes asynchronously)
    /// and then re-checks it. Re-checking rather than trusting local arithmetic is what keeps the
    /// next fix honest: every range then comes from the text as it really is.
    private func recheckAfterWrite(previousText: String) {
        let gen = generation
        Task { @MainActor [weak self] in
            for _ in 0..<12 {
                try? await Task.sleep(nanoseconds: 60_000_000)
                guard let self, gen == self.generation, let element = self.target?.element else { return }
                guard let now = ProofreadAX.currentText(of: element) else { continue }
                if now != previousText { break }
            }
            guard let self, gen == self.generation else { return }
            self.lastCheckedText = "" // force a real check, not a redraw
            self.typingPaused()
        }
    }

    /// Closes the popup and disarms the key tap, leaving the underlines and the found issues alone:
    /// they belong to the field, not to this popup.
    private func endNavigation() {
        currentIndex = 0
        selectedReplacement = 0
        popover.hide()
        setActive(false)
    }

    /// Forgets everything found in the field and takes the underlines down. Used when the focus
    /// moves elsewhere or the feature is switched off.
    private func clearLive() {
        checkTask?.cancel()
        checkTask = nil
        generation &+= 1
        issues = []
        lastCheckedText = ""
        target = nil
        underlines.hide()
    }

    private func end() {
        endNavigation()
        clearLive()
    }

    /// A transient notice that closes itself; never leaves the key tap armed.
    private func flash(_ text: String, spinner: Bool = false) {
        popover.showMessage(text, topLeft: currentAnchor(), spinner: spinner)
        setActive(false)
        guard !spinner else { return }
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, gen == self.generation else { return }
            self.popover.hide()
        }
    }

    // MARK: - Key interception

    /// Arms the tap exactly while the popup is navigable, so ordinary typing never pays for it.
    private func setActive(_ on: Bool) {
        shared.isActive = on
        if on { installTap() }
        guard let tap, on != tapEnabled else { if !on { onSessionChange?(false) }; return }
        tapEnabled = on
        CGEvent.tapEnable(tap: tap, enable: on)
        onSessionChange?(on)
    }

    /// Creates the tap on the main run loop, disabled.
    ///
    /// Autocomplete deliberately keeps its taps off main (see AGENTS.md): its tap sees every
    /// keystroke, so any main-thread hiccup becomes system-wide input lag. This one is different --
    /// it is only enabled while the popup is up, which is a short, deliberate moment when the user is
    /// choosing a fix rather than typing, and the callback only reads a lock-protected flag. If it is
    /// ever left armed while the user types, move it to a dedicated thread like autocomplete's.
    private func installTap() {
        guard tap == nil, AccessibilityPermission.isGranted else { return }
        let mask = (1 << CGEventType.keyDown.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<ProofreadController>.fromOpaque(refcon).takeUnretainedValue()
            return controller.handleKey(type: type, event: event)
        }
        guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                              options: .defaultTap, eventsOfInterest: CGEventMask(mask),
                                              callback: callback, userInfo: userInfo) else { return }
        tap = created
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        tapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: false)
        tapEnabled = false
    }

    /// Runs on the tap thread. Consumes only the popup's own keys and lets everything else through.
    private nonisolated func handleKey(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            DispatchQueue.main.async { [weak self] in
                guard let self, let tap = self.tap, self.tapEnabled else { return }
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown, shared.isActive else { return Unmanaged.passUnretained(event) }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        // Any modifier (including Shift) passes through, so Shift+Return still makes a newline.
        guard !flags.contains(.maskCommand), !flags.contains(.maskControl),
              !flags.contains(.maskAlternate), !flags.contains(.maskShift) else {
            return Unmanaged.passUnretained(event)
        }

        switch keyCode {
        case kVK_UpArrow:
            DispatchQueue.main.async { [weak self] in self?.move(-1) }
            return nil
        case kVK_DownArrow:
            DispatchQueue.main.async { [weak self] in self?.move(1) }
            return nil
        case kVK_Return, kVK_ANSI_KeypadEnter:
            DispatchQueue.main.async { [weak self] in self?.accept() }
            return nil
        case kVK_Tab:
            DispatchQueue.main.async { [weak self] in self?.skip() }
            return nil
        case kVK_Escape:
            // Closes the popup only: the underlines stay, they are not part of this popup.
            DispatchQueue.main.async { [weak self] in self?.endNavigation() }
            return nil
        default:
            // Anything else means the user moved on: close, but let the key reach the field.
            DispatchQueue.main.async { [weak self] in self?.endNavigation() }
            return Unmanaged.passUnretained(event)
        }
    }

    // MARK: - Click monitor

    private func startClickMonitor() {
        guard mouseMonitor == nil else { return }
        // A passive monitor, not a tap: it cannot delay the click. Clicks on our own popup are
        // dispatched to this app and never reach a global monitor, so they cannot retrigger us.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            guard let self else { return }
            self.clickDebounce?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.clickedInText() }
            self.clickDebounce = work
            // Let the app settle its caret/selection before we read it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    private func stopClickMonitor() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        if let appSwitchObserver { NSWorkspace.shared.notificationCenter.removeObserver(appSwitchObserver) }
        appSwitchObserver = nil
        clickDebounce?.cancel()
        clickDebounce = nil
    }

    // MARK: - Typing monitor

    /// Live checking: a passive keyDown monitor (no tap, so typing is never delayed) re-checks the
    /// field once the user pauses. The underlines go down on the first keystroke -- the text under
    /// them is moving -- and come back with the fresh result.
    private func startTypingMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] _ in
            guard let self else { return }
            self.underlines.hide()
            self.typingDebounce?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.typingPaused() }
            self.typingDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + self.typingPause, execute: work)
        }
    }

    private func stopTypingMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        typingDebounce?.cancel()
        typingDebounce = nil
    }

    // MARK: - Helpers

    private func appAllowed() -> Bool {
        let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        if bundle == Bundle.main.bundleIdentifier { return false }
        switch config.appMode {
        case .all: return true
        case .allow: return config.apps.contains(bundle)
        case .deny: return !config.apps.contains(bundle)
        }
    }

    private func anchor(for issue: TextIssue) -> NSPoint {
        let height = primaryScreenHeight()
        if let element = target?.element {
            if let word = ProofreadAX.wordAnchor(for: issue.range, in: element, primaryHeight: height) {
                return word
            }
            if let frame = ProofreadAX.frameAnchor(for: element, primaryHeight: height) { return frame }
        }
        return mouseAnchor()
    }

    private func currentAnchor() -> NSPoint {
        if let issue = issues[safe: currentIndex] { return anchor(for: issue) }
        if let element = target?.element,
           let frame = ProofreadAX.frameAnchor(for: element, primaryHeight: primaryScreenHeight()) {
            return frame
        }
        return mouseAnchor()
    }

    private func mouseAnchor() -> NSPoint {
        let p = NSEvent.mouseLocation
        return NSPoint(x: p.x, y: p.y - 18)
    }

    private func primaryScreenHeight() -> CGFloat? {
        (NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main)?.frame.height
    }

    private static func describe(_ error: Error) -> String {
        if let engineError = error as? EngineError { return engineError.localizedDescription }
        if let urlError = error as? URLError {
            return "LanguageTool server unreachable (\(urlError.code.rawValue))."
        }
        return error.localizedDescription
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
