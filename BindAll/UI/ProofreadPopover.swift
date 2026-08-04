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
    func show(issue: TextIssue, selected: Int, position: String, anchor: CGRect, layout: PopupLayout,
              fontSize: CGFloat, onHover: @escaping (Int) -> Void, onAccept: @escaping (Int) -> Void) {
        let view = PopoverView(title: issue.shortMessage.isEmpty ? issue.message : issue.shortMessage,
                               message: issue.message,
                               original: issue.original,
                               kind: issue.kind,
                               replacements: issue.replacements,
                               selected: selected,
                               layout: layout,
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
    let message: String
    let original: String
    let kind: IssueKind
    let replacements: [String]
    let selected: Int
    let layout: PopupLayout
    /// e.g. "2 of 7"
    let position: String
    /// Base size for the fix rows; the header and hints sit a couple of points below it.
    let fontSize: CGFloat
    let onHover: (Int) -> Void
    let onAccept: (Int) -> Void

    /// Hovering the header swaps the short title for the full explanation.
    @State private var showDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header

            if replacements.isEmpty {
                Text("No suggestions - Tab or arrows for the next word")
                    .font(.system(size: fontSize - 1))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
            } else {
                fixes
            }

            Text(navHint)
                .font(.system(size: fontSize - 3))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 5)
                .padding(.bottom, 3)
        }
        .frame(minWidth: 150, maxWidth: 320, alignment: .leading)
        .padding(2)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .fixedSize()
    }

    /// Kind dot + (short) title, the struck-through original next to the chosen fix, and the issue
    /// position. Hovering shows the rule's full explanation.
    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(showDetail && !message.isEmpty ? message : title)
                    .font(.system(size: fontSize - 2))
                    .foregroundStyle(.secondary)
                    .lineLimit(showDetail ? 4 : 2)
                Spacer(minLength: 8)
                Text(position)
                    .font(.system(size: fontSize - 3))
                    .foregroundStyle(.tertiary)
            }
            if !original.isEmpty {
                HStack(spacing: 5) {
                    Text(original)
                        .strikethrough()
                        .lineLimit(1)
                    if !replacements.isEmpty {
                        Text("→")
                        Text(replacements[selected])
                            .fontWeight(.medium)
                            .lineLimit(1)
                    }
                }
                .font(.system(size: fontSize - 1))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 5)
        .padding(.top, 3)
        .contentShape(Rectangle())
        .onHover { inside in showDetail = inside }
    }

    /// The fixes in the chosen layout: full-width rows in a column, compact chips in a line, and a
    /// two-row grid of chips in the tile (the grid math matches PopupLayout.tileIndex).
    private var fixes: some View {
        Group {
            switch layout {
            case .column:
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(replacementIndices, id: \.self) { row($0) }
                }
            case .line:
                HStack(spacing: 4) {
                    ForEach(replacementIndices, id: \.self) { chip($0) }
                }
            case .tile:
                let columns = PopupLayout.tileColumns(forCount: replacements.count)
                let top = Array(replacementIndices.prefix(columns))
                let bottom = Array(replacementIndices.dropFirst(columns))
                VStack(spacing: 4) {
                    HStack(spacing: 4) { ForEach(top, id: \.self) { chip($0) } }
                    if !bottom.isEmpty {
                        HStack(spacing: 4) { ForEach(bottom, id: \.self) { chip($0) } }
                    }
                }
            }
        }
        .padding(.bottom, 2)
    }

    private var replacementIndices: [Int] { Array(replacements.indices) }

    // Weight is constant so the popup does not resize as the selection moves.
    private func row(_ index: Int) -> some View {
        HStack(spacing: 6) {
            Text("\(index + 1)")
                .font(.system(size: fontSize - 2))
                .foregroundStyle(.tertiary)
                .frame(width: 10, alignment: .trailing)
            Text(replacements[index])
                .font(.system(size: fontSize))
                .foregroundStyle(index == selected ? Color.accentColor : Color.primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if index == selected {
                Text("Return")
                    .font(.system(size: fontSize - 3))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(index == selected ? Color.accentColor.opacity(0.18) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture { onAccept(index) }
        // The guard avoids a hover -> re-render -> hover feedback loop.
        .onHover { inside in if inside && index != selected { onHover(index) } }
    }

    /// Compact numbered cell for the line and tile layouts.
    private func chip(_ index: Int) -> some View {
        HStack(spacing: 4) {
            Text("\(index + 1)")
                .font(.system(size: fontSize - 2))
                .foregroundStyle(.tertiary)
            Text(replacements[index])
                .font(.system(size: fontSize))
                .foregroundStyle(index == selected ? Color.accentColor : Color.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(index == selected ? Color.accentColor.opacity(0.18) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture { onAccept(index) }
        .onHover { inside in if inside && index != selected { onHover(index) } }
    }

    private var navHint: String {
        let choose: String
        switch layout {
        case .column: choose = "↑↓ choose"
        case .line: choose = "←→ choose"
        case .tile: choose = "Arrows choose"
        }
        return "\(choose) · 1-9 pick · Tab next · Esc close"
    }

    private var color: Color { Color(nsColor: kind.underlineColor) }
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .fixedSize()
    }
}
