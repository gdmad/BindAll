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
        let system = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let f = focused else { return .none }
        let element = f as! AXUIElement

        // Never proofread a password field.
        var subroleRef: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef) == .success,
           let subrole = subroleRef as? String, subrole == (kAXSecureTextFieldSubrole as String) {
            return .none
        }

        var valueRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let text = valueRef as? String, !text.isEmpty else { return .none }

        var selection = NSRange(location: (text as NSString).length, length: 0)
        var rangeRef: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success {
            var cfRange = CFRange()
            if AXValueGetValue(rangeRef as! AXValue, .cfRange, &cfRange) {
                selection = NSRange(location: cfRange.location, length: cfRange.length)
            }
        }

        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)

        return .axField(ProofTarget(element: element, pid: pid, text: text,
                                    caret: selection.location, selection: selection))
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
        var cfRange = CFRange(location: range.location, length: max(1, range.length))
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var boundsRef: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         rangeValue, &boundsRef) == .success else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect), rect.width > 0 || rect.height > 0 else {
            return nil
        }
        // Quartz top-left origin -> AppKit bottom-left.
        let base = primaryHeight ?? rect.maxY
        return NSPoint(x: rect.minX, y: base - rect.maxY)
    }

    /// Bottom-left of the element's frame in AppKit screen coordinates, for placing the panel.
    /// `primaryHeight` must be read on the main thread (NSScreen is not safe elsewhere).
    static func frameAnchor(for element: AXUIElement, primaryHeight: CGFloat?) -> NSPoint? {
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
        // Quartz top-left origin -> AppKit bottom-left.
        let base = primaryHeight ?? (pos.y + size.height)
        return NSPoint(x: pos.x, y: base - (pos.y + size.height))
    }
}
