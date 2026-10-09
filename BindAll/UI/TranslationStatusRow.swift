import SwiftUI

/// Whether the selected language pair works offline.
struct TranslationStatusRow: View {
    let autoSource: Bool
    /// nil while unknown.
    let installed: Bool?

    var body: some View {
        if autoSource {
            Label("Source is auto-detected; the pack downloads on first use if needed.",
                  systemImage: "wand.and.stars")
                .font(.caption).foregroundStyle(.secondary)
        } else if let installed {
            if installed {
                Label("Offline ready", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            } else {
                HStack {
                    Label("Will download on first use", systemImage: "arrow.down.circle")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Language Settings", action: TranslationSupport.openLanguageSettings)
                        .controlSize(.small)
                }
            }
        }
    }
}
