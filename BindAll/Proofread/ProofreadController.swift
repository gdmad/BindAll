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

    // Session state.
    private var target: ProofTarget?
    private var issues: [TextIssue] = []
    private var currentIndex = 0
    private var selectedReplacement = 0
    private var checkTask: Task<Void, Never>?
    /// Bumped on every new check and on end(); a result that comes back stale is dropped.
    private var generation = 0

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
        if !config.enabled { end() }
    }

    func stop() {
        end()
        stopClickMonitor()
    }

    // MARK: - Entry points

    /// The Proofread shortcut: check the whole field and start at the first issue.
    func run() {
        guard config.enabled, AccessibilityPermission.isGranted, appAllowed() else { return }
        end()

        switch ProofreadAX.focus() {
        case .axField(let found):
            target = found
            check(text: found.text, offset: 0, startAtFirst: true)
        case .selectionOnly(let text):
            target = nil
            check(text: text, offset: 0, startAtFirst: true)
        case .none:
            // No AX text (Electron, some web fields): fall back to whatever is selected. Fixes then
            // go back through paste rather than in place.
            guard let selection = SelectionReader.copyCurrentSelection(),
                  !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                flash("Select some text, or focus a text field.")
                return
            }
            target = nil
            check(text: selection, offset: 0, startAtFirst: true)
        }
    }

    /// Mouse-up: if the click landed inside a word (or double-clicked one), check the field and show
    /// the fixes for whatever issue that word sits on. Silent when there is nothing to say.
    private func clickedInText() {
        guard config.enabled, config.autoOnClick, AccessibilityPermission.isGranted, appAllowed() else { return }
        guard case .axField(let found) = ProofreadAX.focus() else { return }
        guard found.text.trimmingCharacters(in: .whitespacesAndNewlines).count >= config.minLength else { return }

        let probe: NSRange
        if found.selection.length > 0 {
            // Double-click or drag: reuse the selection when it is word-sized; a long selection is
            // the user copying text, so stay quiet.
            guard found.selection.length <= maxAutoSelection else { return }
            probe = found.selection
        } else if let word = WordBoundary.wordRange(at: found.caret, in: found.text) {
            probe = word
        } else {
            // Clicked whitespace or an empty spot: the user moved on, close any open session.
            if isSessionActive { end() }
            return
        }

        target = found
        check(text: found.text, offset: 0, startAtFirst: false, selection: probe)
    }

    // MARK: - Checking

    /// - Parameters:
    ///   - startAtFirst: true for the shortcut (start at issue 0); false for the auto popup, which
    ///     only shows something if `selection` actually landed on an issue.
    private func check(text: String, offset: Int, startAtFirst: Bool, selection: NSRange? = nil) {
        guard let provider else { return }
        generation &+= 1
        let gen = generation
        checkTask?.cancel()

        if startAtFirst { flash("Checking...", spinner: true) }

        checkTask = Task { [weak self] in
            guard let self else { return }
            do {
                let found = try await provider.check(text)
                guard !Task.isCancelled, gen == self.generation else { return }
                let rebased = offset == 0 ? found : ProofreadCache.rebase(found, to: offset)
                self.applyResults(rebased, startAtFirst: startAtFirst, selection: selection)
            } catch {
                guard !Task.isCancelled, gen == self.generation else { return }
                // Only complain when the user asked for a check; the auto path stays quiet.
                if startAtFirst { self.flash(Self.describe(error)) }
            }
        }
    }

    private func applyResults(_ found: [TextIssue], startAtFirst: Bool, selection: NSRange?) {
        // Cap once at the door so the popup, arrow navigation and accept all see the same list.
        issues = IssueMerger.capReplacements(found, limit: config.maxReplacements)

        if !issues.isEmpty, let element = target?.element {
            underlines.show(issues: issues, element: element)
        }

        if startAtFirst {
            guard !issues.isEmpty else { flash("No issues found."); return }
            focusIssue(0)
            return
        }
        // Auto path: only speak up if the clicked word landed on an issue.
        guard let selection, let issue = IssueMerger.firstIssue(in: issues, overlapping: selection),
              let index = issues.firstIndex(where: { $0.id == issue.id }) else {
            end()
            return
        }
        // Select the issue natively (like the shortcut path) so the user sees exactly what will be
        // replaced before accepting. Safe re-entrancy: the click monitor reacts only to real
        // mouse-ups, and an AX selection write generates none.
        focusIssue(index)
    }

    // MARK: - Session

    private func focusIssue(_ index: Int) {
        guard index >= 0, index < issues.count else { end(); return }
        currentIndex = index
        selectedReplacement = 0
        showCurrent(select: true)
        setActive(true)
    }

    /// Shows the popup for the current issue. `select` also highlights it in the user's field.
    private func showCurrent(select: Bool) {
        guard currentIndex < issues.count else { end(); return }
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
        guard currentIndex + 1 < issues.count else { end(); return }
        focusIssue(currentIndex + 1)
    }

    private func accept() {
        guard let issue = issues[safe: currentIndex],
              let replacement = issue.replacements[safe: selectedReplacement] else { skip(); return }
        guard let target else {
            // No AX element: the best we can do is hand them the corrected word.
            TextInjector.copyToPasteboard(replacement)
            flash("Copied \"\(replacement)\" - this app does not expose its text.")
            return
        }

        switch IssueApplier.apply(issue, replacement: replacement, element: target.element,
                                  pid: target.pid, restoreClipboard: config.restoreClipboard) {
        case .applied(let replacedRange):
            // Slide the remaining ranges locally instead of re-checking: the server round trip would
            // cost a second per fix, and the arithmetic is exact. Shift from the range the applier
            // actually replaced -- relocate may have moved it from the stored issue.range.
            issues = IssueMerger.shift(issues, replacedRange: replacedRange,
                                       replacementUTF16Length: (replacement as NSString).length)
            // Redraw the underlines from the shifted ranges, but only after the write has landed:
            // the paste path applies asynchronously (0.05-0.3 s), so measuring bounds immediately
            // would capture pre-paste geometry.
            underlines.hide()
            let gen = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, gen == self.generation, self.isSessionActive,
                      let element = self.target?.element else { return }
                self.underlines.show(issues: self.issues, element: element)
            }
            if currentIndex >= issues.count { currentIndex = issues.count - 1 }
            if issues.isEmpty { flash("No issues left."); return }
            focusIssue(max(0, currentIndex))
        case .stale:
            flash("The text changed - press the shortcut again.")
        case .failed(let reason):
            flash(reason)
        }
    }

    private func end() {
        checkTask?.cancel()
        checkTask = nil
        generation &+= 1
        issues = []
        currentIndex = 0
        selectedReplacement = 0
        target = nil
        popover.hide()
        underlines.hide()
        setActive(false)
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
            DispatchQueue.main.async { [weak self] in self?.end() }
            return nil
        default:
            // Anything else means the user moved on: close, but let the key reach the field.
            DispatchQueue.main.async { [weak self] in self?.end() }
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
