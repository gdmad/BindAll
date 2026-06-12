import AppKit

/// Lightweight update check against GitHub Releases (no third-party dependency).
/// For silent auto-install, this can later be swapped for Sparkle behind the same entry point.
enum UpdateChecker {
    /// GitHub "owner/repo" that publishes releases.
    static let repository = "gdmad/BindAll"

    /// The project page on GitHub (used by the About section).
    static var repositoryURL: URL { URL(string: "https://github.com/\(repository)")! }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    @MainActor
    static func checkForUpdates() {
        Task {
            do {
                let release = try await latestRelease()
                let latest = release.tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
                if isNewer(latest, than: currentVersion) {
                    presentUpdateAvailable(version: latest, url: release.url)
                } else {
                    presentAlert(title: "You're up to date", message: "BindAll \(currentVersion) is the latest version.")
                }
            } catch {
                presentAlert(title: "Could not check for updates", message: error.localizedDescription)
            }
        }
    }

    // MARK: - Networking

    private struct Release { let tag: String; let url: URL }

    private static func latestRelease() async throws -> Release {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw NSError(domain: "UpdateChecker", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "GitHub returned HTTP \(http.statusCode)."])
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let htmlURL = (json["html_url"] as? String).flatMap(URL.init) else {
            throw NSError(domain: "UpdateChecker", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Unexpected response from GitHub."])
        }
        return Release(tag: tag, url: htmlURL)
    }

    /// Compares dotted numeric versions (e.g. "0.2.0" vs "0.1.15").
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0) ?? 0 } }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - UI

    @MainActor
    private static func presentUpdateAvailable(version: String, url: URL) {
        let alert = NSAlert()
        alert.messageText = "Update available"
        alert.informativeText = "BindAll \(version) is available (you have \(currentVersion))."
        alert.addButton(withTitle: "Open Releases")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(url)
        }
    }

    @MainActor
    private static func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
