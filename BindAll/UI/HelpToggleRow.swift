import SwiftUI

/// A Form-row toggle whose label carries a help hint. Keeps the hint's own `Button` out of the
/// Toggle's tappable label -- nesting a control inside `Toggle(isOn:label:)`'s label works most of
/// the time, but the label's whole area is the toggle's hit target, so a tap that lands on the help
/// icon can end up fighting the toggle for it instead of reliably opening the popover.
struct HelpToggleRow: View {
    let title: String
    let help: String
    @Binding var isOn: Bool

    init(_ title: String, _ help: String, isOn: Binding<Bool>) {
        self.title = title
        self.help = help
        _isOn = isOn
    }

    var body: some View {
        LabeledContent {
            // A switch, like the plain toggles in the same form: inside LabeledContent a Toggle
            // would otherwise fall back to a checkbox.
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        } label: {
            HelpHeader(title, help)
        }
    }
}
