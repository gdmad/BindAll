import Foundation

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
