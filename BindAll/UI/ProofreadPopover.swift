import AppKit
import SwiftUI

/// The small floating list of fixes shown under a problem word.
///
/// Like `AutocompleteOverlay`, this must never take focus: the user's text field stays key so the
/// selection stays visible and the fix lands where they are typing. So: non-activating panel,
/// `orderFront` rather than `makeKey`, and no `NSApp.activate` anywhere.
@MainActor
final class ProofreadPopover {
    private var panel: NSPanel?

    /// Shows `issue`'s fixes with `selected` highlighted, placed above `anchor` -- the word's rect in
    /// AppKit screen coordinates. `onHover`/`onAccept` receive the row index the mouse is on.
    func show(issue: TextIssue, selected: Int, position: String, anchor: CGRect, fontSize: CGFloat,
              onHover: @escaping (Int) -> Void, onAccept: @escaping (Int) -> Void) {
        let view = PopoverView(title: issue.shortMessage.isEmpty ? issue.message : issue.shortMessage,
                               original: issue.original,
                               kind: issue.kind,
                               replacements: issue.replacements,
                               selected: selected,
                               position: position,
                               fontSize: fontSize,
                               onHover: onHover,
                               onAccept: onAccept)
        present(AnyView(view), above: anchor)
    }

    /// A one-line notice (checking, no issues, server error) in the same place as the list.
    func showMessage(_ text: String, anchor: CGRect, fontSize: CGFloat, spinner: Bool = false) {
        present(AnyView(MessageView(text: text, fontSize: fontSize, spinner: spinner)), above: anchor)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func present(_ view: AnyView, above anchor: CGRect) {
        let host = FirstMouseHostingView(rootView: view)
        let panel = self.panel ?? makePanel()
        panel.contentView = host
        panel.layoutIfNeeded()
        let size = host.fittingSize
        panel.setContentSize(size)
        panel.setFrameOrigin(origin(for: size, above: anchor))
        panel.orderFront(nil) // NOT makeKey: the text field must keep focus.
    }

    /// Sits above the word, so the popup never covers what it is about; drops below it only when
    /// there is no room above (a problem word on the top line of the screen).
    private func origin(for size: NSSize, above anchor: CGRect) -> NSPoint {
        let gap: CGFloat = 6
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let above = anchor.maxY + gap
        let below = anchor.minY - gap - size.height
        let y = (above + size.height <= visible.maxY - 4 || below < visible.minY + 4) ? above : below
        return clamp(NSPoint(x: anchor.minX, y: y), size: size)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.ignoresMouseEvents = false // rows accept hover and click-to-apply
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        self.panel = panel
        return panel
    }

    /// Keeps the popup on the screen holding it.
    private func clamp(_ origin: NSPoint, size: NSSize) -> NSPoint {
        let probe = NSPoint(x: origin.x, y: origin.y + size.height / 2)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(probe) }) ?? NSScreen.main else {
            return origin
        }
        let v = screen.visibleFrame
        return NSPoint(x: min(max(origin.x, v.minX + 4), v.maxX - size.width - 4),
                       y: min(max(origin.y, v.minY + 4), v.maxY - size.height - 4))
    }
}

/// The panel is never key, so any click on it is a "first mouse"; accept it so a single click on a
/// row applies the fix instead of just trying (and failing) to focus the panel.
private final class FirstMouseHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Views

private struct PopoverView: View {
    let title: String
    let original: String
    let kind: IssueKind
    let replacements: [String]
    let selected: Int
    /// e.g. "2 of 7"
    let position: String
    /// Base size for the fix rows; the header and hints sit a couple of points below it.
    let fontSize: CGFloat
    let onHover: (Int) -> Void
    let onAccept: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(title)
                    .font(.system(size: fontSize - 2))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(position)
                    .font(.system(size: fontSize - 3))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 5)
            .padding(.top, 3)

            if replacements.isEmpty {
                Text("No suggestions - Tab or arrows for the next word")
                    .font(.system(size: fontSize - 1))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.bottom, 3)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(replacements.enumerated()), id: \.offset) { index, word in
                        row(word, isSelected: index == selected)
                            .contentShape(Rectangle())
                            .onTapGesture { onAccept(index) }
                            // The guard avoids a hover -> re-render -> hover feedback loop.
                            .onHover { inside in if inside && index != selected { onHover(index) } }
                    }
                }
                .padding(.bottom, 2)
            }
        }
        .frame(minWidth: 150, maxWidth: 320, alignment: .leading)
        .padding(2)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary, lineWidth: 1))
        .fixedSize()
    }

    // Weight is constant so the popup does not resize as the selection moves. The selected row uses
    // the system selection colors (the same pill macOS menus use), which adapt to light and dark.
    private func row(_ word: String, isSelected: Bool) -> some View {
        HStack(spacing: 6) {
            Text(word)
                .font(.system(size: fontSize))
                .foregroundStyle(isSelected ? Color(nsColor: .selectedMenuItemTextColor) : Color.primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if isSelected {
                Text("Return")
                    .font(.system(size: fontSize - 3))
                    .foregroundStyle(Color(nsColor: .selectedMenuItemTextColor).opacity(0.85))
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color(nsColor: .selectedContentBackgroundColor) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5))
    }

    /// Matches the underline colors (LanguageTool palette: red spelling, yellow grammar,
    /// green punctuation, blue style).
    private var color: Color {
        switch kind {
        case .spelling: return .red
        case .grammar: return .yellow
        case .punctuation: return .green
        case .style: return .blue
        }
    }
}

private struct MessageView: View {
    let text: String
    let fontSize: CGFloat
    let spinner: Bool

    var body: some View {
        HStack(spacing: 6) {
            if spinner { ProgressView().controlSize(.small).scaleEffect(0.6) }
            Text(text)
                .font(.system(size: fontSize - 1))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary, lineWidth: 1))
        .fixedSize()
    }
}
