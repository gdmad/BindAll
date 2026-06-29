import AppKit
import Carbon.HIToolbox

/// Experimental word autocomplete. Watches typing with a CGEventTap and suggests completions:
///   - In apps that expose it, the focused field's text + caret are read via the Accessibility API.
///   - Elsewhere (Electron/web), the current word is assembled from the observed keystrokes and the
///     chip is anchored near the mouse.
/// A list of candidates is shown near the caret; Up/Down move the selection and Tab inserts it.
///
/// Everything runs on the main thread (the tap source is on the main run loop and deferred work is
/// dispatched to main), so the synchronous suppression decision and the UI calls stay consistent.
final class AutocompleteController {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let overlay = AutocompleteOverlay()

    private var debounce: DispatchWorkItem?

    // Current suggestion state.
    private var candidates: [String] = []
    private var selectedIndex = 0
    private var partial = ""
    private var lastAnchor = NSPoint.zero
    private var hasSuggestion: Bool { !candidates.isEmpty }

    // Fallback "current word" assembled from keystrokes when AX text is unavailable.
    private var typedBuffer = ""

    private let minPrefix = 3
    /// Marks keystrokes we inject so the tap ignores them.
    private let injectedMarker: Int64 = 0x424E444C // "BNDL"

    var isRunning: Bool { eventTap != nil }

    func start() {
        guard eventTap == nil, AccessibilityPermission.isGranted else { return }
        let mask = (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<AutocompleteController>.fromOpaque(refcon).takeUnretainedValue()
            return controller.handle(type: type, event: event)
        }
        // Not listen-only: the tap must be able to suppress Tab / arrows while a suggestion is showing.
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: CGEventMask(mask),
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        runLoopSource = nil
        eventTap = nil
        debounce?.cancel()
        debounce = nil
        resetWord()
    }

    // MARK: - Event handling

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        // Ignore the keystrokes we inject ourselves.
        if event.getIntegerValueField(.eventSourceUserData) == injectedMarker {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let modified = flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate)

        // While a suggestion is visible, consume the keys that drive it.
        if hasSuggestion, !modified {
            switch keyCode {
            case kVK_Tab:
                let index = selectedIndex
                DispatchQueue.main.async { [weak self] in self?.accept(index: index) }
                return nil
            case kVK_UpArrow:
                DispatchQueue.main.async { [weak self] in self?.move(-1) }
                return nil
            case kVK_DownArrow:
                DispatchQueue.main.async { [weak self] in self?.move(1) }
                return nil
            case kVK_Escape:
                DispatchQueue.main.async { [weak self] in self?.clearSuggestion() }
                return nil
            default:
                break
            }
        }

        let typed = unicodeString(from: event)
        DispatchQueue.main.async { [weak self] in self?.onKey(keyCode: keyCode, typed: typed, modified: modified) }
        return Unmanaged.passUnretained(event)
    }

    private func onKey(keyCode: Int, typed: String, modified: Bool) {
        let navKeys: Set<Int> = [kVK_Escape, kVK_Return, kVK_ANSI_KeypadEnter, kVK_LeftArrow, kVK_RightArrow,
                                 kVK_UpArrow, kVK_DownArrow, kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_Space]
        if modified || navKeys.contains(keyCode) {
            resetWord()
            return
        }
        if keyCode == kVK_Delete {
            typedBuffer = String(typedBuffer.dropLast())
        } else if typed.count == 1, let scalar = typed.unicodeScalars.first, CharacterSet.letters.contains(scalar) {
            typedBuffer.append(typed)
        } else {
            resetWord() // boundary (digit, punctuation, etc.)
            return
        }

        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: work)
    }

    // MARK: - Suggestion lifecycle

    private func refresh() {
        let anchor: NSPoint
        switch focusState() {
        case .secure:
            resetWord(); return
        case .text(let info):
            partial = AutocompleteEngine.partialWord(in: info.text, caretUTF16Offset: info.caret)
            typedBuffer = partial // keep the fallback buffer in sync with the truth
            anchor = caretAnchor(for: info.element, caret: info.caret) ?? mouseAnchor()
        case .unavailable:
            partial = typedBuffer
            anchor = mouseAnchor()
        }

        guard partial.count >= minPrefix else { clearSuggestion(); return }
        let list = AutocompleteEngine.suggestions(for: partial, limit: 5)
        guard !list.isEmpty else { clearSuggestion(); return }

        candidates = list
        selectedIndex = 0
        lastAnchor = anchor
        overlay.show(list, selected: 0, topLeft: anchor)
    }

    private func move(_ delta: Int) {
        guard !candidates.isEmpty else { return }
        selectedIndex = max(0, min(candidates.count - 1, selectedIndex + delta))
        overlay.show(candidates, selected: selectedIndex, topLeft: lastAnchor)
    }

    private func accept(index: Int) {
        guard index >= 0, index < candidates.count else { clearSuggestion(); return }
        let word = candidates[index]
        let current = partial
        typedBuffer = word
        clearSuggestion()
        insert(word: word, replacing: current)
    }

    private func clearSuggestion() {
        candidates = []
        selectedIndex = 0
        overlay.hide()
    }

    private func resetWord() {
        typedBuffer = ""
        partial = ""
        clearSuggestion()
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

    /// AppKit screen point just below the caret, derived from the AX caret rect (Quartz, top-left).
    private func caretAnchor(for element: AXUIElement, caret: Int) -> NSPoint? {
        var cfRange = CFRange(location: max(0, caret - 1), length: 1)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var boundsRef: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         rangeValue, &boundsRef) == .success else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect), rect.width > 0 || rect.height > 0 else { return nil }
        let primaryHeight = (NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main)?
            .frame.height ?? rect.maxY
        return NSPoint(x: rect.minX, y: primaryHeight - rect.maxY)
    }

    private func mouseAnchor() -> NSPoint {
        let p = NSEvent.mouseLocation
        return NSPoint(x: p.x, y: p.y - 18)
    }

    // MARK: - Injection

    private func unicodeString(from event: CGEvent) -> String {
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &chars)
        return length > 0 ? String(utf16CodeUnits: chars, count: length) : ""
    }

    private func insert(word: String, replacing partial: String) {
        if word.lowercased().hasPrefix(partial.lowercased()) {
            let suffix = String(word.dropFirst(partial.count))
            if !suffix.isEmpty { typeString(suffix) }
        } else {
            deleteBackward(count: (partial as NSString).length)
            typeString(word)
        }
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
        down.setIntegerValueField(.eventSourceUserData, value: injectedMarker)
        up.setIntegerValueField(.eventSourceUserData, value: injectedMarker)
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }

    private func deleteBackward(count: Int) {
        guard count > 0 else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        for _ in 0..<count {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: false) else { continue }
            down.setIntegerValueField(.eventSourceUserData, value: injectedMarker)
            up.setIntegerValueField(.eventSourceUserData, value: injectedMarker)
            down.post(tap: .cgAnnotatedSessionEventTap)
            up.post(tap: .cgAnnotatedSessionEventTap)
        }
    }
}
