import SwiftUI

/// Panel background, border and padding, shared by both popups.
///
/// Reads Reduce Transparency from the environment rather than from `NSWorkspace`, so it follows the
/// system setting on its own instead of only when the popup happens to be rebuilt.
struct PopupChrome: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: PopupMetrics.containerRadius)
        content
            .padding(PopupMetrics.containerPadding)
            .background(reduceTransparency ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
                                           : AnyShapeStyle(.regularMaterial),
                        in: shape)
            .overlay { shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1) }
            .fixedSize()
    }
}

extension View {
    func popupChrome() -> some View { modifier(PopupChrome()) }
}
