import AppKit

/// A registered hotkey the monitor should watch for.
struct WatchedHotkey: Hashable {
    var keyCode: UInt16
    var modifiers: HotkeyModifiers
    /// Highest press count any action expects for this key+modifiers. Once reached, the burst fires
    /// immediately instead of waiting out the window (no point waiting for a press that cannot match).
    var maxRepeat: Int = 1
}

/// Passive CGEventTap that detects repeated key presses (e.g. Cmd+C pressed N times in a row)
/// without consuming the events, so normal copy still works.
final class HotkeyMonitor {
    /// How long a burst waits for another press before firing (when more presses are still possible).
    /// A single app-wide constant; it is not a user-facing or stored setting.
    static let burstWindow: TimeInterval = 0.35

    /// Called on the main thread when a burst of identical presses ends.
    var onBurst: ((UInt16, HotkeyModifiers, Int) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var watched: [WatchedHotkey] = []

    private struct BurstState {
        var count: Int
        var workItem: DispatchWorkItem?
    }
    private var bursts: [String: BurstState] = [:]

    func setWatched(_ hotkeys: [WatchedHotkey]) {
        watched = hotkeys
    }

    var isRunning: Bool { eventTap != nil }

    func start() -> Bool {
        guard eventTap == nil else { return true }
        let mask = (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            if type == .keyDown {
                monitor.handle(event: event)
            } else if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = monitor.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            }
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
        bursts.removeAll()
    }

    // MARK: - Private

    private func handle(event: CGEvent) {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let relevant: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate]
        let flags = event.flags.intersection(relevant)
        let mods = HotkeyModifiers(
            command: flags.contains(.maskCommand),
            option: flags.contains(.maskAlternate),
            control: flags.contains(.maskControl),
            shift: flags.contains(.maskShift)
        )

        guard let match = watched.first(where: { $0.keyCode == keyCode && $0.modifiers == mods }) else {
            return
        }

        let key = "\(keyCode)|\(mods.command)\(mods.option)\(mods.control)\(mods.shift)"
        let window = Self.burstWindow
        let maxRepeat = match.maxRepeat

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var state = self.bursts[key] ?? BurstState(count: 0, workItem: nil)
            state.workItem?.cancel()
            state.count += 1
            let count = state.count

            // Highest expected press count reached: fire now instead of waiting out the window.
            if count >= maxRepeat {
                self.bursts[key] = nil
                self.onBurst?(keyCode, mods, count)
                return
            }

            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.bursts[key] = nil
                self.onBurst?(keyCode, mods, count)
            }
            state.workItem = work
            self.bursts[key] = state
            DispatchQueue.main.asyncAfter(deadline: .now() + window, execute: work)
        }
    }
}
