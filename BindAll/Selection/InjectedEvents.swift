import AppKit

/// Keystrokes BindAll synthesizes itself (autocomplete insertions, the paste that applies a fix).
///
/// Both features watch the keyboard: autocomplete through its taps, proofread through a passive
/// monitor that re-checks the field after a pause. Without a marker each would react to the other's
/// synthetic keys -- and proofread would react to its own paste, hiding the underlines and starting a
/// second re-check on top of the one the applier already schedules.
enum InjectedEvents {
    private static let marker: Int64 = 0x424E444C // "BNDL"

    static func mark(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: marker)
    }

    static func isInjected(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == marker
    }

    static func isInjected(_ event: NSEvent) -> Bool {
        guard let cgEvent = event.cgEvent else { return false }
        return isInjected(cgEvent)
    }
}
