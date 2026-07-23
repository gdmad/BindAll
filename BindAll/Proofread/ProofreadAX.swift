import AppKit
import ApplicationServices

/// The focused text field, its contents and the caret/selection.
struct ProofTarget {
    let element: AXUIElement
    let pid: pid_t
    let text: String
    /// UTF-16 offset of the caret (selection start).
    let caret: Int
    let selection: NSRange
}

enum ProofSource {
    /// The field's whole text was read over the Accessibility API and can be edited in place.
    case axField(ProofTarget)
    /// Only the selection is available (no AX text); fixes go through select-and-paste.
    case selectionOnly(String)
    /// Nothing to check: no focus, a password field, or a field that exposes no text.
    case none
}

/// Accessibility access for the proofreading pipeline.
///
/// This deliberately duplicates ~50 lines of `AutocompleteController.focusState()` rather than
/// sharing them. That code runs under hard latency constraints on its own tap thread; coupling the
/// two features to save a few lines would put this feature's changes in that path.
enum ProofreadAX {
    /// Reads the focused field. Unlike autocomplete, a non-empty selection is fine: it means the user
    /// wants that range checked.
    static func focus() -> ProofSource {
        enableElectronAccessibilityIfNeeded()
        guard let focused = focusedElement() else { return .none }
        if isSecure(focused) { return .none }

        // The focused element is not always the one holding the text: web areas and composite
        // controls hand the text to a nested element, and a click can land on a wrapper.
        for candidate in textCandidates(around: focused) {
            guard !isSecure(candidate),
                  let text = currentText(of: candidate), !text.isEmpty else { continue }

            var selection = NSRange(location: (text as NSString).length, length: 0)
            if let range = selectedRange(of: candidate) { selection = range }

            var pid: pid_t = 0
            AXUIElementGetPid(candidate, &pid)
            return .axField(ProofTarget(element: candidate, pid: pid, text: text,
                                        caret: selection.location, selection: selection))
        }

        // No readable field text, but the app may still expose the selection (many web views do).
        if let selected = selectedText(of: focused),
           !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .selectionOnly(selected)
        }
        return .none
    }

    /// Chromium-based apps (Electron: Slack, VS Code, Discord…) build their accessibility tree only
    /// when an assistive app asks for it, via the private `AXManualAccessibility` attribute. Without
    /// this their fields expose no text and no word coordinates at all. Done once per process.
    private static var accessibilityEnabledPids = Set<pid_t>()

    static func enableElectronAccessibilityIfNeeded() {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              !accessibilityEnabledPids.contains(pid) else { return }
        accessibilityEnabledPids.insert(pid)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    /// The system-wide focused element.
    static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let f = focused else { return nil }
        return (f as! AXUIElement)
    }

    /// Elements that may hold the field's text, nearest first: the focused element itself, its own
    /// focused descendant, text children, then a text parent.
    static func textCandidates(around element: AXUIElement) -> [AXUIElement] {
        var out = [element]

        var nestedRef: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &nestedRef) == .success,
           let nested = nestedRef {
            out.append(nested as! AXUIElement)
        }

        var childrenRef: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            out.append(contentsOf: children.prefix(10).filter(isTextRole))
        }

        var parentRef: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parentRef) == .success,
           let parent = parentRef {
            let p = parent as! AXUIElement
            if isTextRole(p) { out.append(p) }
        }
        return out
    }

    static func role(of element: AXUIElement) -> String? {
        var roleRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success else {
            return nil
        }
        return roleRef as? String
    }

    static func subrole(of element: AXUIElement) -> String? {
        var subroleRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef) == .success else {
            return nil
        }
        return subroleRef as? String
    }

    private static func isTextRole(_ element: AXUIElement) -> Bool {
        guard let role = role(of: element) else { return false }
        return role == (kAXTextAreaRole as String) || role == (kAXTextFieldRole as String)
    }

    /// Never proofread a password field.
    private static func isSecure(_ element: AXUIElement) -> Bool {
        subrole(of: element) == (kAXSecureTextFieldSubrole as String)
    }

    /// Re-reads the element's current text, for validating an issue before applying its fix.
    static func currentText(of element: AXUIElement) -> String? {
        var valueRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success else {
            return nil
        }
        return valueRef as? String
    }

    /// Selects `range` in the field, so the user sees the issue highlighted natively in their own app.
    @discardableResult
    static func select(_ range: NSRange, in element: AXUIElement) -> Bool {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    /// The element's current selection range, or nil when the attribute is unreadable. Used to
    /// confirm that a select() actually took before pasting over the "selection".
    static func selectedRange(of element: AXUIElement) -> NSRange? {
        var rangeRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success else {
            return nil
        }
        var cfRange = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &cfRange) else { return nil }
        return NSRange(location: cfRange.location, length: cfRange.length)
    }

    /// The element's current selected text, or nil when the attribute is unreadable.
    static func selectedText(of element: AXUIElement) -> String? {
        var textRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &textRef) == .success else {
            return nil
        }
        return textRef as? String
    }

    /// Whether the element lets us write text straight into the selection (the clean, in-place path).
    static func canSetSelectedText(_ element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success else {
            return false
        }
        return settable.boolValue
    }

    /// A point just below the word at `range`, for anchoring the popup to it.
    ///
    /// Only one strategy: ask the element for the range's bounds. Apps that do not answer (many
    /// Electron and web fields) fall back to the element frame, and the feature still works -- the
    /// popup is just placed less precisely. `primaryHeight` must be read on the main thread.
    static func wordAnchor(for range: NSRange, in element: AXUIElement, primaryHeight: CGFloat?) -> NSPoint? {
        guard let rect = boundsForRange(range, in: element) else { return nil }
        // Quartz top-left origin -> AppKit bottom-left.
        let base = primaryHeight ?? rect.maxY
        return NSPoint(x: rect.minX, y: base - rect.maxY)
    }

    /// Screen bounds of `range` (Quartz, top-left origin); nil when the app does not answer or
    /// answers with an empty rect (many Electron and web fields).
    static func boundsForRange(_ range: NSRange, in element: AXUIElement) -> CGRect? {
        var cfRange = CFRange(location: range.location, length: max(1, range.length))
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var boundsRef: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         rangeValue, &boundsRef) == .success else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect), rect.width > 0 || rect.height > 0 else {
            return nil
        }
        return rect
    }

    /// Bottom-left of the element's frame in AppKit screen coordinates, for placing the panel.
    /// `primaryHeight` must be read on the main thread (NSScreen is not safe elsewhere).
    static func frameAnchor(for element: AXUIElement, primaryHeight: CGFloat?) -> NSPoint? {
        guard let rect = frame(of: element) else { return nil }
        // Quartz top-left origin -> AppKit bottom-left.
        let base = primaryHeight ?? rect.maxY
        return NSPoint(x: rect.minX, y: base - rect.maxY)
    }

    /// The element's screen frame (Quartz, top-left origin).
    static func frame(of element: AXUIElement) -> CGRect? {
        var posRef: AnyObject?
        var sizeRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success else {
            return nil
        }
        var pos = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &pos),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size),
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: pos, size: size)
    }
}
