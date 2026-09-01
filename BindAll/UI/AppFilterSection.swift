import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The "which apps does this feature run in" section, shared by Autocomplete and Proofread.
///
/// Both features filter by bundle identifier in exactly the same way, so they get exactly the same
/// control: the two tabs used to carry near-identical copies that had drifted apart (only one of
/// them could add an app that was not currently running).
struct AppFilterSection: View {
    let title: String
    let help: String
    /// "Show in" for autocomplete, "Check in" for proofread.
    let modeLabel: String
    @Binding var mode: String
    @Binding var apps: [String]

    var body: some View {
        Section {
            Picker(modeLabel, selection: $mode) {
                Text("All apps").tag("all")
                Text("Only selected apps").tag("allow")
                Text("All except selected").tag("deny")
            }
            if mode != "all" {
                ForEach(apps, id: \.self) { bundleID in
                    HStack {
                        Text(Self.appName(bundleID))
                        Spacer()
                        Button {
                            apps.removeAll { $0 == bundleID }
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Menu("Add app…") {
                    Menu("Running apps") {
                        ForEach(Self.runningApps(), id: \.id) { app in
                            Button(app.name) { add(app.id) }
                        }
                    }
                    Button("Choose from disk…") { addFromDisk() }
                }
                .controlSize(.small)
                .fixedSize()
            }
        } header: {
            helpHeader(title, help)
        }
    }

    private func add(_ bundleID: String) {
        guard !apps.contains(bundleID) else { return }
        apps.append(bundleID)
    }

    private func addFromDisk() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        add(bundleID)
    }

    static func appName(_ bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url.deletingPathExtension().lastPathComponent
        }
        return bundleID
    }

    /// Currently-running regular apps (includes Safari/Chrome web apps while they run), sorted by name.
    static func runningApps() -> [(id: String, name: String)] {
        let mine = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        var apps: [(id: String, name: String)] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier, id != mine, !seen.contains(id) else { continue }
            seen.insert(id)
            apps.append((id: id, name: app.localizedName ?? id))
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
