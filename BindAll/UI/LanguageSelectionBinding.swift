import SwiftUI

/// Bindings onto a list of language codes, for the per-language toggles in a menu. Kept out of view
/// bodies: a menu `Toggle` needs a `Binding<Bool>` per item, and there is no stored Bool to bind.
extension Binding where Value == [String] {
    /// On when `code` is in the list; toggling adds or removes it.
    func contains(_ code: String) -> Binding<Bool> {
        Binding<Bool>(
            get: { wrappedValue.contains(code) },
            set: { isOn in
                var list = wrappedValue
                if isOn {
                    if !list.contains(code) { list.append(code) }
                } else {
                    list.removeAll { $0 == code }
                }
                wrappedValue = list
            }
        )
    }

    /// On when the list is empty ("Auto"); turning it on empties the list.
    var isAuto: Binding<Bool> {
        Binding<Bool>(
            get: { wrappedValue.isEmpty },
            set: { isOn in if isOn { wrappedValue = [] } }
        )
    }
}
