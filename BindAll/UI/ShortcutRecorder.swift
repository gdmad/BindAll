import SwiftUI

/// A click-to-record shortcut field. Captures a modifier+key chord; pressing the same chord again
/// within a short window increases the press count (shown as ⌘C, ⌘C+C, ...). Rejects duplicates.
struct ShortcutRecorder: View {
    @EnvironmentObject var appState: AppState
    @Binding var config: HotkeyConfig?
    /// The other shortcuts to check against for duplicates.
    let others: [HotkeyConfig]
    /// When true (optional mode), a clear button removes the shortcut entirely.
    var allowsClear: Bool = false

    /// Required shortcut (the four built-ins): bridges a non-optional binding. The recorder works on
    /// an optional (action keys can have none), and a non-optional value has to be adapted to it.
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
    @State private var finalizeTask: Task<Void, Never>?
    @State private var conflict = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggleRecording) {
                Text(displayText)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 90)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.fieldFill(for: colorScheme)))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(borderColor, lineWidth: (isRecording || conflict) ? 2 : 1)
            )

            if isRecording {
                Button("Cancel recording", systemImage: "xmark.circle.fill", action: cancelRecording)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            } else if allowsClear, config != nil {
                Button("Remove shortcut", systemImage: "xmark.circle.fill", action: clearShortcut)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Remove shortcut")
            }
        }
        .help(conflict ? "This shortcut is already used by another action." : "")
        .onDisappear { stopRecording(apply: false) }
    }

    private var borderColor: AnyShapeStyle {
        if conflict { AnyShapeStyle(.red) } else if isRecording { AnyShapeStyle(.tint) } else { AnyShapeStyle(.separator) }
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

    private func clearShortcut() {
        config = nil
    }

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

    /// Waits a moment for the same chord again (⌘C+C) before taking what was pressed.
    private func scheduleFinalize() {
        finalizeTask?.cancel()
        finalizeTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            finalize()
        }
    }

    private func finalize() {
        guard let code = pendingKeyCode else { return }
        let new = HotkeyConfig(keyCode: code, modifiers: pendingMods, repeatCount: pendingCount)
        let isDuplicate = others.contains {
            $0.keyCode == new.keyCode && $0.modifiers == new.modifiers && $0.repeatCount == new.repeatCount
        }
        if isDuplicate {
            conflict = true
            stopRecording(apply: false)
            Task {
                try? await Task.sleep(for: .seconds(1.6))
                conflict = false
            }
            return
        }
        config = new
        stopRecording(apply: true)
    }

    private func cancelRecording() {
        stopRecording(apply: false)
    }

    private func stopRecording(apply: Bool) {
        finalizeTask?.cancel()
        finalizeTask = nil
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        isRecording = false
        pendingKeyCode = nil
        pendingCount = 0
        // Guarded and deferred: onDisappear runs inside the tab-switch view update, and an
        // unconditional @Published assignment there logs "Publishing changes from within view
        // updates" for every recorder being torn down.
        if appState.isRecordingShortcut {
            Task { @MainActor in appState.isRecordingShortcut = false }
        }
    }
}
