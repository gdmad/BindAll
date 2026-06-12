import SwiftUI

@main
struct BindAllApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The visible UI (status-bar item + settings window) is managed by AppDelegate using AppKit,
        // which is the most reliable approach for an LSUIElement menu-bar agent. This placeholder
        // Settings scene simply satisfies SwiftUI's "App must have a Scene" requirement.
        SwiftUI.Settings {
            EmptyView()
        }
    }
}
