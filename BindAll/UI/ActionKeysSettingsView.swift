import SwiftUI

struct ActionKeysSettingsView: View {
    @EnvironmentObject var appState: AppState
    /// A key added in this session opens expanded, ready to be filled in.
    @State private var newKeyID: ActionKey.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Iterate over values (diffed by id) and bind by id — never by index — so deleting a row
            // can't leave a stale index binding (which crashes with "Index out of range").
            ForEach(appState.settings.actionKeys) { key in
                ActionKeyRow(key: binding(for: key.id),
                             others: otherShortcuts(excluding: key.id),
                             startsExpanded: key.id == newKeyID,
                             delete: { delete(key.id) })
            }

            Button("Add action key", systemImage: "plus", action: addKey)
                .controlSize(.small)
                .padding(.top, 4)
        }
    }

    private func addKey() {
        let new = ActionKey(key: "", label: "", prompt: "")
        newKeyID = new.id
        appState.settings.actionKeys.append(new)
    }

    private func delete(_ id: ActionKey.ID) {
        appState.settings.actionKeys.removeAll { $0.id == id }
    }

    /// All shortcuts an action-key recorder must not collide with: the four built-ins plus the
    /// shortcuts of every other action key.
    private func otherShortcuts(excluding id: ActionKey.ID) -> [HotkeyConfig] {
        let s = appState.settings
        let builtIn = [s.defaultActionHotkey, s.translateHotkey, s.screenTranslateHotkey, s.quickTranslateHotkey]
        let keys = s.actionKeys.filter { $0.id != id }.compactMap(\.hotkey)
        return builtIn + keys
    }

    /// A binding that resolves the action key by id on every access, so it stays valid even as the
    /// array is mutated (added/removed) elsewhere. `ForEach($array)` binds by index instead, which is
    /// exactly the stale binding that crashed on delete -- the one place a hand-made binding is right.
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
