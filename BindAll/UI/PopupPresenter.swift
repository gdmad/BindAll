import AppKit
import SwiftUI

/// Owns a popup's panel and puts a SwiftUI view in it. Both popups did this by hand, one through an
/// `AnyView` so that a single method could take two different views; being generic removes that.
///
/// The panel never becomes key: the user's text field keeps focus so the caret stays where they are
/// typing. So `orderFront` rather than `makeKey`, and no `NSApp.activate` anywhere.
final class PopupPresenter {
    private var panel: NSPanel?
    /// Autocomplete ignores mouse events entirely; the proofread popup accepts them, because its rows
    /// can be clicked.
    private let ignoresMouseEvents: Bool

    init(ignoresMouseEvents: Bool) {
        self.ignoresMouseEvents = ignoresMouseEvents
    }

    /// Shows `view`, placed by `origin`, which is handed the view's fitted size.
    func present<Content: View>(_ view: Content, origin: (NSSize) -> NSPoint) {
        let host = FirstMouseHostingView(rootView: view)
        let panel = self.panel ?? makePanel()
        panel.contentView = host
        panel.layoutIfNeeded()
        let size = host.fittingSize
        panel.setContentSize(size)
        panel.setFrameOrigin(origin(size))
        panel.orderFront(nil) // NOT makeKey: the text field must keep focus.
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = PopupPanel.make(ignoresMouseEvents: ignoresMouseEvents)
        self.panel = panel
        return panel
    }
}
