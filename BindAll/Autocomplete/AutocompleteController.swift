import AppKit
import Carbon.HIToolbox

/// Experimental word autocomplete. Watches typing with a CGEventTap, reads the focused field via the
/// Accessibility API to find the word being typed and the caret position, asks `AutocompleteEngine`
/// for a completion, and shows it in a floating chip near the caret. Pressing Tab while a suggestion
/// is visible inserts the missing suffix.
///
/// Everything runs on the main thread (the tap source is attached to the main run loop and all
/// deferred work is dispatched to main), so the synchronous suppression decision and the UI calls are
/// consistent without extra synchronization.
final class AutocompleteController {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let overlay = AutocompleteOverlay()

    private var debounce: DispatchWorkItem?
    private var hasSuggestion = false
    private var pendingSuffix = ""

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
        // Not listen-only: the tap must be able to suppress Tab when a suggestion is showing.
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
        clearSuggestion()
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

        // Accept with Tab while a suggestion is visible: suppress the Tab and insert the suffix.
        if keyCode == kVK_Tab, hasSuggestion, !modified {
            let suffix = pendingSuffix
            DispatchQueue.main.async { [weak self] in self?.accept(suffix: suffix) }
            return nil
        }

        DispatchQueue.main.async { [weak self] in self?.scheduleRefresh(keyCode: keyCode, modified: modified) }
        return Unmanaged.passUnretained(event)
    }

    private func scheduleRefresh(keyCode: Int, modified: Bool) {
        let dismissKeys: Set<Int> = [kVK_Escape, kVK_Return, kVK_ANSI_KeypadEnter, kVK_Tab, kVK_Space,
                                     kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
                                     kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown]
        if modified || dismissKeys.contains(keyCode) {
            clearSuggestion()
            return
        }
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: work)
    }

    private func refresh() {
        guard let info = focusedTextInfo() else { clearSuggestion(); return }
        let partial = AutocompleteEngine.partialWord(in: info.text, caretUTF16Offset: info.caret)
        guard partial.count >= minPrefix,
              let completion = AutocompleteEngine.completion(for: partial),
              completion.count > partial.count,
              let rect = caretRect(for: info.element, caret: info.caret) else {
            clearSuggestion()
            return
        }
        pendingSuffix = String(completion.dropFirst(partial.count))
        hasSuggestion = true
        overlay.show(completion, at: rect)
    }

    private func accept(suffix: String) {
        clearSuggestion()
        guard !suffix.isEmpty else { return }
        typeString(suffix)
    }

    private func clearSuggestion() {
        hasSuggestion = false
        pendingSuffix = ""
        overlay.hide()
    }

    // MARK: - Accessibility reads

    private struct TextInfo {
        let element: AXUIElement
        let text: String
        let caret: Int
    }

    private func focusedTextInfo() -> TextInfo? {
        let system = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let f = focused else { return nil }
        let element = f as! AXUIElement

        var valueRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let text = valueRef as? String else { return nil }

        var rangeRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range), range.length == 0 else { return nil }

        return TextInfo(element: element, text: text, caret: range.location)
    }

    private func caretRect(for element: AXUIElement, caret: Int) -> CGRect? {
        var cfRange = CFRange(location: max(0, caret - 1), length: 1)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var boundsRef: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         rangeValue, &boundsRef) == .success else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect), rect.width > 0 || rect.height > 0 else { return nil }
        return rect
    }

    // MARK: - Injection

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
}
