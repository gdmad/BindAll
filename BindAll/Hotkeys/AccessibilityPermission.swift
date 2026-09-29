import AppKit
import ApplicationServices

enum AccessibilityPermission {
    /// Whether the app is currently trusted for the Accessibility API.
    static var isGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Whether Input Monitoring is granted. All of BindAll's `CGEventTap`s are `.cgSessionEventTap`,
    /// which is satisfied by either Accessibility or Input Monitoring -- this is diagnostic only, to
    /// tell the two apart in logs when a tap fails to install; it never prompts on its own.
    static var listenEventAccessGranted: Bool {
        CGPreflightListenEventAccess()
    }

    /// Prompts the user (system dialog) to grant Accessibility access if not already trusted.
    @discardableResult
    static func requestIfNeeded() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Opens System Settings at the Accessibility privacy pane. The modern pane extension URL works
    /// from macOS 13 on; the older preference-pane URL is kept as a fallback in case a future macOS
    /// drops it (openURL cannot report why it failed, only whether the call was accepted at all).
    static func openSystemSettings() {
        let modern = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")!
        let legacy = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(modern, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard error != nil else { return }
            NSWorkspace.shared.open(legacy)
        }
    }
}
