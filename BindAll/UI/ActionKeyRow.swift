import SwiftUI

/// One action key: a summary line that expands into its editor.
struct ActionKeyRow: View {
    @Binding var key: ActionKey
    let others: [HotkeyConfig]
    let delete: () -> Void

    @State private var isExpanded: Bool

    init(key: Binding<ActionKey>, others: [HotkeyConfig], startsExpanded: Bool, delete: @escaping () -> Void) {
        _key = key
        self.others = others
        self.delete = delete
        _isExpanded = State(initialValue: startsExpanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Key").foregroundStyle(.secondary)
                    TextField("Key", text: deferredWrite($key.key), prompt: Text("key"))
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.leading)
                        .monospaced()
                        .frame(width: 140)
                        .darkField()
                    Spacer()
                    Text("Shortcut").foregroundStyle(.secondary)
                    ShortcutRecorder(optionalConfig: $key.hotkey, others: others)
                }

                HStack(spacing: 8) {
                    Text("Name").foregroundStyle(.secondary)
                    TextField("Name", text: deferredWrite($key.label), prompt: Text("What this key does"))
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .darkField()
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Instruction").foregroundStyle(.secondary)
                    TextField("Instruction", text: deferredWrite($key.prompt),
                              prompt: Text("Describe the action for the AI…"), axis: .vertical)
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3...8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .darkField()
                }

                HStack {
                    Spacer()
                    Button("Delete", systemImage: "trash", role: .destructive, action: delete)
                        .controlSize(.small)
                }
            }
            .padding(.vertical, 4)
        } label: {
            // The whole summary line toggles the row, not just the chevron.
            Button(action: toggle) {
                HStack(spacing: 8) {
                    Text(key.key.isEmpty ? "—" : key.key)
                        .monospaced()
                        .bold()
                    // The name if there is one -- the built-in keys ship with good ones -- and the
                    // instruction itself otherwise.
                    Text(key.label.isEmpty ? key.prompt : key.label)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }

    private func toggle() {
        isExpanded.toggle()
    }
}
