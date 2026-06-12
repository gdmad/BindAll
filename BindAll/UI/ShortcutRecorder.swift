import SwiftUI
import AppKit

/// Formats a HotkeyConfig as glyphs, e.g. ⌘C, ⇧⌘E, or ⌘C+C for a double press.
enum HotkeyFormatter {
    static func string(_ c: HotkeyConfig) -> String {
        string(keyCode: c.keyCode, mods: c.modifiers, count: c.repeatCount)
    }

    static func string(keyCode: UInt16, mods: HotkeyModifiers, count: Int) -> String {
        var s = ""
        if mods.control { s += "⌃" }
        if mods.option { s += "⌥" }
        if mods.shift { s += "⇧" }
        if mods.command { s += "⌘" }
        let key = keyName(keyCode).uppercased()
        s += key
        if count > 1 { s += String(repeating: "+\(key)", count: count - 1) }
        return s
    }

    static func keyName(_ code: UInt16) -> String { keyNames[code] ?? "Key\(code)" }

    static let keyNames: [UInt16: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J",
        40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T",
        32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
        49: "Space", 36: "Return", 48: "Tab",
    ]
}

/// A click-to-record shortcut field. Captures a modifier+key chord; pressing the same chord again
/// within a short window increases the press count (shown as ⌘C, ⌘C+C, ...). Rejects duplicates.
struct ShortcutRecorder: View {
    @EnvironmentObject var appState: AppState
    @Binding var config: HotkeyConfig?
    /// The other shortcuts to check against for duplicates.
    let others: [HotkeyConfig]
    /// When true (optional mode), a clear button removes the shortcut entirely.
    var allowsClear: Bool = false

    /// Required shortcut (the four built-ins): bridges a non-optional binding.
    init(config: Binding<HotkeyConfig>, others: [HotkeyConfig]) {
        self._config = Binding(get: { config.wrappedValue }, set: { if let v = $0 { config.wrappedValue = v } })
        self.others = others
        self.allowsClear = false
    }

    /// Optional shortcut (action keys): nil shows "Record Shortcut" and can be cleared.
    init(optionalConfig: Binding<HotkeyConfig?>, others: [HotkeyConfig]) {
        self._config = optionalConfig
        self.others = others
        self.allowsClear = true
    }

    @State private var isRecording = false
    @State private var pendingKeyCode: UInt16?
    @State private var pendingMods = HotkeyModifiers(command: false)
    @State private var pendingCount = 0
    @State private var monitor: Any?
    @State private var finalizeWork: DispatchWorkItem?
    @State private var conflict = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggleRecording) {
                Text(displayText)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 90)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.fieldFill(for: colorScheme)))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(borderColor, lineWidth: (isRecording || conflict) ? 2 : 1)
            )

            if isRecording {
                Button(action: cancelRecording) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else if allowsClear, config != nil {
                Button {
                    config = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove shortcut")
            }
        }
        .help(conflict ? "This shortcut is already used by another action." : "")
        .onDisappear { stopRecording(apply: false) }
    }

    private var borderColor: Color {
        if conflict { return .red }
        if isRecording { return .accentColor }
        return Color(nsColor: .separatorColor)
    }

    private var displayText: String {
        if isRecording {
            if let code = pendingKeyCode {
                return HotkeyFormatter.string(keyCode: code, mods: pendingMods, count: pendingCount)
            }
            return "Press shortcut…"
        }
        guard let config else { return "Record Shortcut" }
        return HotkeyFormatter.string(config)
    }

    // MARK: - Recording

    private func toggleRecording() {
        isRecording ? cancelRecording() : startRecording()
    }

    private func startRecording() {
        conflict = false
        pendingKeyCode = nil
        pendingCount = 0
        isRecording = true
        appState.isRecordingShortcut = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handle(event)
            return nil // consume so the keystroke does not reach text fields / menus
        }
    }

    private func handle(_ event: NSEvent) {
        let code = event.keyCode
        if code == 53 { cancelRecording(); return } // Esc cancels

        let flags = event.modifierFlags
        let mods = HotkeyModifiers(
            command: flags.contains(.command),
            option: flags.contains(.option),
            control: flags.contains(.control),
            shift: flags.contains(.shift)
        )
        guard !mods.isEmpty else { return } // a shortcut needs at least one modifier

        if pendingKeyCode == code, pendingMods == mods {
            pendingCount += 1
        } else {
            pendingKeyCode = code
            pendingMods = mods
            pendingCount = 1
        }
        scheduleFinalize()
    }

    private func scheduleFinalize() {
        finalizeWork?.cancel()
        let work = DispatchWorkItem { finalize() }
        finalizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    private func finalize() {
        guard let code = pendingKeyCode else { return }
        let new = HotkeyConfig(keyCode: code, modifiers: pendingMods, repeatCount: pendingCount,
                               windowMilliseconds: config?.windowMilliseconds ?? 400)
        let isDuplicate = others.contains {
            $0.keyCode == new.keyCode && $0.modifiers == new.modifiers && $0.repeatCount == new.repeatCount
        }
        if isDuplicate {
            conflict = true
            stopRecording(apply: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { conflict = false }
            return
        }
        config = new
        stopRecording(apply: true)
    }

    private func cancelRecording() {
        stopRecording(apply: false)
    }

    private func stopRecording(apply: Bool) {
        finalizeWork?.cancel()
        finalizeWork = nil
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        isRecording = false
        pendingKeyCode = nil
        pendingCount = 0
        appState.isRecordingShortcut = false
    }
}
