import AppKit
import ApplicationServices

enum AccessibilityPermission {
    /// Whether the app is currently trusted for the Accessibility API.
    static var isGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Prompts the user (system dialog) to grant Accessibility access if not already trusted.
    @discardableResult
    static func requestIfNeeded() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Opens System Settings at the Accessibility privacy pane.
    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
