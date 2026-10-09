import SwiftUI

struct GeneralSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var launchAtLogin = LoginItemManager.isEnabled

    var body: some View {
        Form {
            Section {
                HelpToggleRow("BindAll enabled", "The master switch, the same one the menu bar carries. Off: the global shortcuts, autocomplete and proofreading all stand down until it is back on.",
                              isOn: $appState.settings.enabled)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in applyLaunchAtLogin(enabled) }
            } header: {
                Text("Startup")
            }

            Section("Output") {
                HelpToggleRow("Restore clipboard after replacing", "When replacing the selection, BindAll puts the result on the clipboard and pastes it. With this on, your previous clipboard contents are restored a moment after pasting, so the tool does not overwrite what you had copied. Off: the result stays on the clipboard.",
                              isOn: $appState.settings.restoreClipboard)
                HelpToggleRow("Mask AI Slop", "Normalizes typical 'AI' typography in results: em/en dashes become '-', smart quotes and apostrophes become straight ones, and emoji and unusual unicode are stripped.",
                              isOn: $appState.settings.maskAISlop)
                HelpToggleRow("Keep history", "Stores the last 50 results locally (menu bar > History) so a closed popup or overwritten paste can be recovered. Stored on this Mac only; never includes API keys.",
                              isOn: $appState.settings.historyEnabled)
            }

            Section {
                Stepper("Text size: \(appState.settings.popupFontSize) pt",
                        value: $appState.settings.popupFontSize, in: 10...20)
            } header: {
                HelpHeader("Popups", "The floating popups: autocomplete suggestions and proofread fixes. Both use this text size.")
            }

            Section {
                LabeledContent("Accessibility") {
                    if appState.accessibilityGranted {
                        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Grant Access…", action: AccessibilityPermission.openSystemSettings)
                    }
                }
                LabeledContent("Global shortcuts") {
                    if appState.hotkeysActive {
                        Label("Active", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Label("Not active", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                LabeledContent("Apple on-device model", value: appState.appleEngineStatus)
            } header: {
                HelpHeader("Status", "Live status. Accessibility is required for the global shortcuts and for pasting results back into the active app. \"Global shortcuts\" can show Not active even with Accessibility granted -- that means the permission is stale (common right after a macOS upgrade); remove BindAll from the Accessibility list in System Settings and grant it again. Apple on-device model shows whether Apple Intelligence is available for the on-device engine.")
            }

            Section("About") {
                LabeledContent("Version", value: UpdateChecker.currentVersion)
                LabeledContent("Source code") {
                    Link("GitHub", destination: UpdateChecker.repositoryURL)
                }
                Button("Check for Updates…", action: UpdateChecker.checkForUpdates)
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = LoginItemManager.isEnabled }
    }

    /// The system can refuse (e.g. approval pending in System Settings), so the toggle re-reads the
    /// real state instead of trusting what was asked for.
    private func applyLaunchAtLogin(_ enabled: Bool) {
        LoginItemManager.apply(enabled)
        let actual = LoginItemManager.isEnabled
        if actual != launchAtLogin { launchAtLogin = actual }
    }
}
