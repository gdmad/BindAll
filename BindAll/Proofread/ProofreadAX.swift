import AppKit
import ApplicationServices
import os

private let log = Logger(subsystem: "com.evgeny.bindall", category: "proofread-ax")

/// The focused text field, its contents and the caret/selection.
struct ProofTarget {
    let element: AXUIElement
    let pid: pid_t
    let text: String
    /// UTF-16 offset of the caret (selection start).
    let caret: Int
    let selection: NSRange
    /// Block boundaries the app shows but leaves out of `text` (see `HiddenBreaks`).
    var breaks: HiddenBreaks = .none
    /// How `text` offsets translate into the app's own, when the two differ (see `AppOffsetMap`).
    var offsetMap: AppOffsetMap?
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

            var pid: pid_t = 0
            AXUIElementGetPid(candidate, &pid)
            // A web area's own pid is often a renderer/helper process, distinct from the frontmost
            // app pid that `enableElectronAccessibilityIfNeeded` tested -- without this, `isChromium`
            // would read false for the one pid that actually matters (IssueApplier, showCurrent).
            if pid != 0, let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
               pid != frontPid, chromiumPids.contains(frontPid) {
                chromiumPids.insert(pid)
            }
            let chromium = isChromium(pid: pid)
            let breaks = chromium ? hiddenBreaks(in: candidate, text: text) : .none
            let map = chromium ? offsetMap(for: candidate, text: text) : nil
            // The selection is reported in the app's offsets; everything downstream works in the
            // value's, so it is translated back before anyone measures a word with it.
            var selection = NSRange(location: (text as NSString).length, length: 0)
            if let range = selectedRange(of: candidate) {
                if let map {
                    let start = map.valueOffset(range.location)
                    selection = NSRange(location: start, length: map.valueOffset(NSMaxRange(range)) - start)
                } else {
                    selection = range
                }
            }
            return .axField(ProofTarget(element: candidate, pid: pid, text: text,
                                        caret: selection.location, selection: selection, breaks: breaks,
                                        offsetMap: map))
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
    /// Processes that accepted `AXManualAccessibility` -- only Chromium implements it, so this
    /// doubles as a reliable "this is an Electron/Chromium app" test.
    private static var chromiumPids = Set<pid_t>()

    /// Every AX call below is synchronous and made from the main thread, so a hung or slow target
    /// app would otherwise hang BindAll's own UI (and its active proofread tap) along with it.
    private static let axMessagingTimeout: Float = 0.25

    static func enableElectronAccessibilityIfNeeded() {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              !accessibilityEnabledPids.contains(pid) else { return }
        let app = AXUIElementCreateApplication(pid)
        // Building a Chromium app's whole accessibility tree on this call can take longer than the
        // messaging timeout below -- set it only afterwards, or the timeout cuts off detection itself
        // and every Chromium app (Slack included) is permanently misread as native.
        let status = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if status == .success {
            chromiumPids.insert(pid)
            accessibilityEnabledPids.insert(pid)
        } // else: retry next time -- a slow success now looks identical to a real native app
        AXUIElementSetMessagingTimeout(app, axMessagingTimeout)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    /// Chromium reports `kAXSelectedText` as settable but applies the write asynchronously, so it
    /// can be neither verified nor trusted; such apps take the paste path instead.
    static func isChromium(pid: pid_t) -> Bool { chromiumPids.contains(pid) }

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

    /// The text the app itself reports for `range` (`AXStringForRange`), or nil when it does not
    /// answer. This is the only trustworthy way to check a range in apps whose value offsets and
    /// selection offsets do not line up -- Chromium being the notable one.
    static func string(for range: NSRange, in element: AXUIElement) -> String? {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard range.length > 0, let value = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var result: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, value, &result) == .success else {
            return nil
        }
        return result as? String
    }

    /// The app's own text, read through `AXStringForRange` in chunks (Slack refuses one range over the
    /// whole field), lined up against `text`. Nil when the two are the same or cannot be lined up.
    /// Cached for the last text: underlines, clicks and fixes all ask about the same one.
    static func offsetMap(for element: AXUIElement, text: String) -> AppOffsetMap? {
        if let cached = mapCache, cached.text == text, CFEqual(cached.element, element) { return cached.map }
        var app = ""
        var location = 0
        var chunk = 256
        let limit = (text as NSString).length + 1
        while location < limit {
            guard let piece = string(for: NSRange(location: location, length: chunk), in: element) else {
                if chunk > 1 { chunk /= 2; continue }
                break
            }
            let length = (piece as NSString).length
            guard length > 0 else { break }
            app += piece
            location += length
            if length < chunk { break }
        }
        let map = AppOffsetMap(value: text, app: app).flatMap { $0.isIdentity ? nil : $0 }
        if map == nil, app != text {
            log.debug("offset map: app text (\((app as NSString).length, privacy: .public)) does not line up with the value (\((text as NSString).length, privacy: .public))")
        }
        mapCache = (element, text, map)
        return map
    }

    private static var mapCache: (element: AXUIElement, text: String, map: AppOffsetMap?)?

    /// Confirms `range` really holds `original` according to the app, shifting by up to `window`
    /// UTF-16 units to find it when the app's offsets differ from ours. Returns nil when the app
    /// answers but nothing nearby matches, and `range` unchanged when it cannot answer at all.
    /// With `map`, the exact translation is tried first; the search below is for apps without one.
    static func alignedRange(_ range: NSRange, expecting original: String, in element: AXUIElement,
                             contextBefore: String = "", contextAfter: String = "",
                             window: Int? = nil, map: AppOffsetMap? = nil) -> NSRange? {
        if let map, let mapped = map.appRange(range), string(for: mapped, in: element) == original {
            return mapped
        }
        guard let here = string(for: range, in: element) else { return range } // app cannot tell us
        if here == original, contextMatches(range, contextBefore, contextAfter, in: element) {
            return range
        }
        // The window scales with how far into the text the range sits: a fixed small window is what
        // let this silently give up on long documents where an app's own offset drift grows with
        // position (observed after a macOS upgrade changed an app's AX offset bookkeeping). But that
        // only works when there is a context snapshot to confirm a candidate against -- with none,
        // `contextMatches` is a no-op (nothing to compare), and scanning wide bumped straight into
        // trying +1 first at the end of a field, landing on the neighbouring text instead of refusing.
        let hasContext = !contextBefore.isEmpty || !contextAfter.isEmpty
        let effectiveWindow = window ?? (hasContext ? max(16, min(256, range.location / 20)) : 16)
        // Offsets disagree: probe outwards, nearest first, and take the first match the surrounding
        // text agrees with -- the same word can sit elsewhere in the field.
        for distance in 1...effectiveWindow {
            for offset in [distance, -distance] {
                let candidate = NSRange(location: range.location + offset, length: range.length)
                guard candidate.location >= 0, string(for: candidate, in: element) == original,
                      contextMatches(candidate, contextBefore, contextAfter, in: element) else { continue }
                return candidate
            }
        }
        log.debug("alignedRange found nothing matching near \(range.location, privacy: .public) within ±\(effectiveWindow, privacy: .public)")
        return nil
    }

    /// Whether the text the app reports around `range` still matches the snapshot taken at check
    /// time. An empty snapshot (legacy issues, or the click path) means "nothing to disagree with".
    private static func contextMatches(_ range: NSRange, _ before: String, _ after: String,
                                       in element: AXUIElement) -> Bool {
        let span = 6
        let beforeNS = before as NSString
        if beforeNS.length > 0, range.location > 0 {
            let length = min(span, min(beforeNS.length, range.location))
            let expected = beforeNS.substring(from: beforeNS.length - length)
            if let actual = string(for: NSRange(location: range.location - length, length: length), in: element),
               actual != expected {
                return false
            }
        }
        let afterNS = after as NSString
        if afterNS.length > 0 {
            let length = min(span, afterNS.length)
            let expected = afterNS.substring(to: length)
            if let actual = string(for: NSRange(location: NSMaxRange(range), length: length), in: element),
               actual != expected {
                return false
            }
        }
        return true
    }

    /// Whether the element lets us write text straight into the selection (the clean, in-place path).
    static func canSetSelectedText(_ element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success else {
            return false
        }
        return settable.boolValue
    }

    /// Screen bounds of `range` (Quartz, top-left origin); nil when neither the element nor its leaf
    /// text descendants answer (many Electron and web fields keep the geometry on the leaves).
    static func boundsForRange(_ range: NSRange, in element: AXUIElement,
                               expecting expected: String? = nil) -> CGRect? {
        if let rect = rawBounds(range, in: element) { return rect }
        return boundsFromLeaves(range, in: element, expecting: expected)
    }

    /// One `AXBoundsForRange` question, with the answer sanity-checked.
    static func rawBounds(_ range: NSRange, in element: AXUIElement) -> CGRect? {
        var cfRange = CFRange(location: range.location, length: max(1, range.length))
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var boundsRef: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         rangeValue, &boundsRef) == .success,
              let value = boundsRef, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect), rect.width > 0 || rect.height > 0 else {
            return nil
        }
        return rect
    }

    /// Walks the leaf text descendants, mapping the field-wide `range` onto the leaf that holds it.
    static func boundsFromLeaves(_ range: NSRange, in element: AXUIElement,
                                 expecting expected: String? = nil) -> CGRect? {
        var offset = 0
        for leaf in textLeaves(of: element) {
            let ns = leaf.text as NSString
            let length = ns.length
            defer { offset += length }
            guard range.location >= offset, range.location < offset + length else { continue }
            let local = NSRange(location: range.location - offset,
                                length: min(range.length, length - (range.location - offset)))
            // The leaves need not be laid out the way the field's value is (Obsidian splits by
            // formatting), so trust the offset only when the leaf's own text agrees.
            if let expected, ns.substring(with: local) != expected {
                let found = ns.range(of: expected, options: [.literal])
                guard found.location != NSNotFound, let rect = rawBounds(found, in: leaf.element) else { continue }
                return rect
            }
            if let rect = rawBounds(local, in: leaf.element) { return rect }
        }
        // Offsets did not line up with any leaf: look for the text itself, nearest leaf first.
        guard let expected else { return nil }
        for leaf in textLeaves(of: element) {
            let found = (leaf.text as NSString).range(of: expected, options: [.literal])
            guard found.location != NSNotFound, let rect = rawBounds(found, in: leaf.element) else { continue }
            return rect
        }
        return nil
    }

    /// Finds the list items, quotes and code blocks that a Chromium field shows on separate lines but
    /// reports glued together in its value. The leaves are matched against the value one by one, so
    /// list markers and other text that is not in the value are skipped instead of spoiling the rest.
    static func hiddenBreaks(in element: AXUIElement, text: String) -> HiddenBreaks {
        let leaves = textLeaves(of: element, depth: 6, budget: 200)
        guard leaves.count > 1 else { return .none }
        let pieces = leaves.map(\.text)
        let breaks = HiddenBreaks.find(pieces: pieces, in: text) { previous, next in
            let lastIndex = (pieces[previous] as NSString).length - 1
            guard let end = rawBounds(NSRange(location: lastIndex, length: 1), in: leaves[previous].element),
                  let start = rawBounds(NSRange(location: 0, length: 1), in: leaves[next].element) else {
                return false
            }
            return isLower(start, than: end)
        }
        let matched = HiddenBreaks.align(pieces: pieces, in: text).compactMap { $0 }.count
        log.debug("hidden breaks: \(breaks.offsets.count, privacy: .public) from \(matched, privacy: .public) of \(leaves.count, privacy: .public) leaves matched")
        return breaks
    }

    /// The safety net for a break `hiddenBreaks` could not see: whether `issue` sits across a line
    /// break the field leaves out of its text, judged by where the characters are on screen.
    static func crossesVisualBreak(_ issue: TextIssue, text: String, in element: AXUIElement,
                                   map: AppOffsetMap? = nil) -> Bool {
        let seams = HiddenBreaks.seamCandidates(of: issue, in: text)
        guard !seams.isEmpty else { return false }
        let ns = text as NSString
        // Measured in the app's own offsets, and through the text leaves when the field itself has
        // no geometry (Slack answers the field-wide query with an empty rect).
        func bounds(_ offset: Int) -> CGRect? {
            let ours = NSRange(location: offset, length: 1)
            guard let range = map?.appRange(ours) ?? Optional(ours), range.length > 0 else { return nil }
            return boundsForRange(range, in: element, expecting: ns.substring(with: ours))
        }
        return seams.contains { seam in
            guard let left = bounds(seam - 1), let right = bounds(seam) else { return false }
            return isLower(right, than: left)
        }
    }

    /// Quartz coordinates: a lower line has a larger y. The slack absorbs mixed font sizes.
    private static func isLower(_ rect: CGRect, than other: CGRect) -> Bool {
        rect.minY >= other.maxY - 2
    }

    /// Leaf elements carrying text, in reading order (depth-limited: these trees can be large).
    static func textLeaves(of element: AXUIElement, depth: Int = 3, budget: Int = 40) -> [(element: AXUIElement, text: String)] {
        guard depth > 0, budget > 0 else { return [] }
        var childrenRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return [] }

        var out: [(element: AXUIElement, text: String)] = []
        var left = budget
        for child in children {
            guard left > 0 else { break }
            left -= 1
            if let text = currentText(of: child), !text.isEmpty {
                out.append((element: child, text: text))
            } else {
                let nested = textLeaves(of: child, depth: depth - 1, budget: left)
                left -= nested.count
                out.append(contentsOf: nested)
            }
        }
        return out
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
