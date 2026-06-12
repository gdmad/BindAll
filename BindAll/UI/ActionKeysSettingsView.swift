import SwiftUI

struct ActionKeysSettingsView: View {
    @EnvironmentObject var appState: AppState
    /// Rows that are currently expanded. Newly added keys are inserted here so they open expanded.
    @State private var expanded: Set<ActionKey.ID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Iterate over values (diffed by id) and bind by id — never by index — so deleting a row
            // can't leave a stale index binding (which crashes with "Index out of range").
            ForEach(appState.settings.actionKeys) { key in
                DisclosureGroup(isExpanded: expandedBinding(for: key.id)) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text("Key").foregroundStyle(.secondary)
                            TextField("", text: binding(for: key.id).key, prompt: Text("key"))
                                .labelsHidden()
                                .textFieldStyle(.plain)
                                .multilineTextAlignment(.leading)
                                .font(.system(.body, design: .monospaced))
                                .frame(width: 140)
                                .darkField()
                            Spacer()
                            Text("Shortcut").foregroundStyle(.secondary)
                            ShortcutRecorder(optionalConfig: binding(for: key.id).hotkey,
                                             others: otherShortcuts(excluding: key.id))
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Instruction").foregroundStyle(.secondary)
                            TextField("", text: binding(for: key.id).prompt,
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
                            Button(role: .destructive) {
                                appState.settings.actionKeys.removeAll { $0.id == key.id }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 4)
                } label: {
                    HStack(spacing: 8) {
                        Text(key.key.isEmpty ? "—" : key.key)
                            .font(.system(.body, design: .monospaced)).bold()
                        Text(key.prompt)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    // Make the whole header row toggle the row, not just the chevron.
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if expanded.contains(key.id) {
                            expanded.remove(key.id)
                        } else {
                            expanded.insert(key.id)
                        }
                    }
                }
            }

            Button {
                let new = ActionKey(key: "", label: "", prompt: "")
                appState.settings.actionKeys.append(new)
                expanded.insert(new.id)
            } label: {
                Label("Add action key", systemImage: "plus")
            }
            .controlSize(.small)
            .padding(.top, 4)
        }
    }

    /// All shortcuts an action-key recorder must not collide with: the four built-ins plus the
    /// shortcuts of every other action key.
    private func otherShortcuts(excluding id: ActionKey.ID) -> [HotkeyConfig] {
        let s = appState.settings
        let builtIn = [s.defaultActionHotkey, s.translateHotkey, s.screenTranslateHotkey, s.quickTranslateHotkey]
        let keys = s.actionKeys.filter { $0.id != id }.compactMap(\.hotkey)
        return builtIn + keys
    }

    private func expandedBinding(for id: ActionKey.ID) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(id) },
            set: { isOpen in
                if isOpen { expanded.insert(id) } else { expanded.remove(id) }
            }
        )
    }

    /// A binding that resolves the action key by id on every access, so it stays valid even as the
    /// array is mutated (added/removed) elsewhere.
    private func binding(for id: ActionKey.ID) -> Binding<ActionKey> {
        Binding(
            get: {
                appState.settings.actionKeys.first(where: { $0.id == id })
                    ?? ActionKey(key: "", label: "", prompt: "")
            },
            set: { newValue in
                if let index = appState.settings.actionKeys.firstIndex(where: { $0.id == id }) {
                    appState.settings.actionKeys[index] = newValue
                }
            }
        )
    }
}
