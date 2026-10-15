import SwiftUI

/// "Skip": leaves this one place alone. An icon beside the counter rather than a row of its own --
/// it is an action on the issue, not one of the fixes -- with its name kept for VoiceOver and the
/// tooltip. Reached with the arrows as the last choice, so it highlights like a fix when selected.
struct FixesPopupSkipButton: View {
    let isSelected: Bool
    let fontSize: CGFloat
    let onHover: () -> Void
    let onActivate: () -> Void

    var body: some View {
        PopupCell(text: "Skip this issue", isSelected: isSelected,
                  fontSize: PopupMetrics.counterFontSize(fontSize),
                  systemImage: "eye.slash", isSecondary: true, showsTitle: false, onActivate: onActivate)
            .onHover { inside in if inside && !isSelected { onHover() } }
            .help("Skip this issue")
    }
}
