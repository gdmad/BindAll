import ServiceManagement
import os

/// Manages the "Launch at login" state via the modern ServiceManagement API.
enum LoginItemManager {
    private static let log = Logger(subsystem: "com.evgeny.bindall", category: "login-item")

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// The Settings toggle binds directly to this; on failure the toggle simply reflects `isEnabled`
    /// again on the next read (SMAppService can refuse registration, e.g. outside /Applications), so
    /// logging here is what makes an otherwise-silent snap-back explainable.
    static func apply(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            log.error("failed to \(enabled ? "register" : "unregister", privacy: .public) login item: \(error.localizedDescription, privacy: .public)")
        }
    }
}
