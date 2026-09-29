import SwiftUI

/// The popup panel is never key, so any click on it is a "first mouse"; accept it so a single click on
/// a row applies the fix instead of just trying (and failing) to focus the panel.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
