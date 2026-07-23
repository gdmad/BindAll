import AppKit
import ApplicationServices

/// Reports what the Accessibility API exposes for the currently focused field. Proofread depends
/// entirely on that, so when nothing happens in an app this answers why: no permission, no readable
/// text, or no word coordinates (which is what underlining needs).
enum ProofreadDiagnostics {
    /// Whether the last report found a field with readable text, so the caller can keep polling
    /// until the user has clicked into the app they want to test.
    private(set) static var foundReadableField = false

    /// Collects the report. Call on the main thread, with the field the user wants to test focused.
    static func report(liveIssueCount: Int, error: String?) -> String {
        foundReadableField = false
        var lines: [String] = []
        lines.append("Accessibility trusted: \(AXIsProcessTrusted())")
        // Chromium/Electron builds its tree only when asked; do it before reading anything.
        ProofreadAX.enableElectronAccessibilityIfNeeded()

        if let app = NSWorkspace.shared.frontmostApplication {
            lines.append("Frontmost app: \(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "no bundle id"), pid \(app.processIdentifier))")
            lines.append("Chromium/Electron: \(ProofreadAX.isChromium(pid: app.processIdentifier))")
            if app.bundleIdentifier == Bundle.main.bundleIdentifier {
                lines.append("NOTE: focus was on BindAll itself - click into another app's text field and run this again.")
            }
        } else {
            lines.append("Frontmost app: none")
        }

        guard let focused = ProofreadAX.focusedElement() else {
            lines.append("Focused element: none (the app exposes no focused UI element)")
            return lines.joined(separator: "\n")
        }
        lines.append("Focused element: role \(ProofreadAX.role(of: focused) ?? "?"), subrole \(ProofreadAX.subrole(of: focused) ?? "-")")

        let candidates = ProofreadAX.textCandidates(around: focused)
        lines.append("Text candidates examined: \(candidates.count)")
        for (index, candidate) in candidates.enumerated() {
            let role = ProofreadAX.role(of: candidate) ?? "?"
            if let text = ProofreadAX.currentText(of: candidate), !text.isEmpty {
                lines.append("  [\(index)] \(role): \((text as NSString).length) UTF-16 units of text")
            } else {
                lines.append("  [\(index)] \(role): no readable text")
            }
        }

        switch ProofreadAX.focus() {
        case .axField(let target):
            foundReadableField = true
            lines.append("Result: readable field (\((target.text as NSString).length) UTF-16 units)")
            lines.append("Selection: location \(target.selection.location), length \(target.selection.length)")
            lines.append("Can write into the selection: \(ProofreadAX.canSetSelectedText(target.element))")
            let probe = WordBoundary.wordRange(at: 0, in: target.text)
                ?? NSRange(location: 0, length: min(3, (target.text as NSString).length))
            if let rect = ProofreadAX.boundsForRange(probe, in: target.element) {
                lines.append("Word coordinates: yes \(Int(rect.origin.x)),\(Int(rect.origin.y)) \(Int(rect.width))x\(Int(rect.height)) - underlines work here")
            } else {
                lines.append("Word coordinates: NO - this app cannot show underlines (fixes still work)")
            }
            var paramNames: CFArray?
            if AXUIElementCopyParameterizedAttributeNames(target.element, &paramNames) == .success,
               let names = paramNames as? [String] {
                lines.append("Parameterized attributes: \(names.isEmpty ? "none" : names.joined(separator: ", "))")
            } else {
                lines.append("Parameterized attributes: unavailable")
            }
            if let frame = ProofreadAX.frame(of: target.element) {
                lines.append("Field frame: \(Int(frame.origin.x)),\(Int(frame.origin.y)) \(Int(frame.width))x\(Int(frame.height))")
            } else {
                lines.append("Field frame: unavailable")
            }
        case .selectionOnly(let text):
            lines.append("Result: only the selection is readable (\(text.count) characters); no field text, so no underlines")
        case .none:
            lines.append("Result: nothing readable - proofread cannot work in this field")
        }

        lines.append("Issues currently underlined: \(liveIssueCount)")
        if let error { lines.append("Last check error: \(error)") }
        return lines.joined(separator: "\n")
    }
}
