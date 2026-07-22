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

    /// Shows `issue`'s fixes with `selected` highlighted, anchored so its top-left sits at `topLeft`
    /// (AppKit screen coordinates). `onHover`/`onAccept` receive the row index the mouse is on.
    func show(issue: TextIssue, selected: Int, position: String, topLeft: NSPoint,
              onHover: @escaping (Int) -> Void, onAccept: @escaping (Int) -> Void) {
        let view = PopoverView(title: issue.shortMessage.isEmpty ? issue.message : issue.shortMessage,
                               original: issue.original,
                               kind: issue.kind,
                               replacements: issue.replacements,
                               selected: selected,
                               position: position,
                               onHover: onHover,
                               onAccept: onAccept)
        present(AnyView(view), at: topLeft)
    }

    /// A one-line notice (checking, no issues, server error) in the same place as the list.
    func showMessage(_ text: String, topLeft: NSPoint, spinner: Bool = false) {
        present(AnyView(MessageView(text: text, spinner: spinner)), at: topLeft)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func present(_ view: AnyView, at topLeft: NSPoint) {
        let host = FirstMouseHostingView(rootView: view)
        let panel = self.panel ?? makePanel()
        panel.contentView = host
        panel.layoutIfNeeded()
        let size = host.fittingSize
        panel.setContentSize(size)
        panel.setFrameOrigin(clamp(NSPoint(x: topLeft.x, y: topLeft.y - size.height), size: size))
        panel.orderFront(nil) // NOT makeKey: the text field must keep focus.
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

    /// Keeps the popup on the screen holding the anchor.
    private func clamp(_ origin: NSPoint, size: NSSize) -> NSPoint {
        let anchor = NSPoint(x: origin.x, y: origin.y + size.height)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main else {
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
    let onHover: (Int) -> Void
    let onAccept: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(position)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 5)
            .padding(.top, 3)

            if replacements.isEmpty {
                Text("No suggestions - Tab to skip")
                    .font(.system(size: 12))
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .fixedSize()
    }

    // Weight is constant so the popup does not resize as the selection moves.
    private func row(_ word: String, isSelected: Bool) -> some View {
        HStack(spacing: 6) {
            Text(word)
                .font(.system(size: 13))
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if isSelected {
                Text("Return")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 4))
    }

    private var color: Color {
        switch kind {
        case .spelling: return .red
        case .grammar: return .orange
        case .punctuation: return .blue
        case .style: return .gray
        }
    }
}

private struct MessageView: View {
    let text: String
    let spinner: Bool

    var body: some View {
        HStack(spacing: 6) {
            if spinner { ProgressView().controlSize(.small).scaleEffect(0.6) }
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .fixedSize()
    }
}
