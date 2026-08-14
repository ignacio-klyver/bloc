import AppKit
import Carbon.HIToolbox

/// The global shortcut, stored in preferences so it can be changed without rebuilding.
///
/// There is no reliable way to ask macOS which combinations other applications have already
/// taken: apps register through Carbon, through event taps, or through their own agents, and
/// none of that is enumerable from outside. So the app does not pretend to know. It ships a
/// default, says out loud which combination it is actually holding, and lets the user move it.
struct Shortcut: Equatable {
    var keyCode: UInt32
    /// Carbon modifier mask (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`).
    var modifiers: UInt32

    /// ⌥⌘B. Deliberately not ⌘⇧Space, which 1Password's Quick Access takes by default.
    static let fallback = Shortcut(keyCode: UInt32(kVK_ANSI_B),
                                   modifiers: UInt32(optionKey | cmdKey))

    private static let keyCodeDefault = "shortcutKeyCode"
    private static let modifiersDefault = "shortcutModifiers"

    static var current: Shortcut {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: keyCodeDefault) != nil else { return fallback }
        return Shortcut(keyCode: UInt32(defaults.integer(forKey: keyCodeDefault)),
                        modifiers: UInt32(defaults.integer(forKey: modifiersDefault)))
    }

    func save() {
        UserDefaults.standard.set(Int(keyCode), forKey: Shortcut.keyCodeDefault)
        UserDefaults.standard.set(Int(modifiers), forKey: Shortcut.modifiersDefault)
    }

    // MARK: Display

    private static let names: [UInt32: String] = [
        UInt32(kVK_Space): "Space", UInt32(kVK_Return): "Return", UInt32(kVK_Tab): "Tab",
        UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
        UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
        UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
        UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
        UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
        UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
        UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
        UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
        UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
        UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2", UInt32(kVK_ANSI_3): "3",
        UInt32(kVK_ANSI_Comma): ",", UInt32(kVK_ANSI_Period): ".",
    ]

    /// `⌥⌘B`
    var display: String {
        var out = ""
        if modifiers & UInt32(controlKey) != 0 { out += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { out += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { out += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { out += "⌘" }
        return out + (Shortcut.names[keyCode] ?? "tecla \(keyCode)")
    }

    // MARK: Parsing

    /// Accepts `cmd+shift+space`, `alt+cmd+b`, `ctrl+opt+n`. Case and order do not matter.
    static func parse(_ spec: String) -> Shortcut? {
        var modifiers: UInt32 = 0
        var key: UInt32?

        for rawPart in spec.lowercased().split(whereSeparator: { $0 == "+" || $0 == "-" }) {
            let part = rawPart.trimmingCharacters(in: .whitespaces)
            switch part {
            case "cmd", "command", "⌘": modifiers |= UInt32(cmdKey)
            case "shift", "⇧":          modifiers |= UInt32(shiftKey)
            case "alt", "opt", "option", "⌥": modifiers |= UInt32(optionKey)
            case "ctrl", "control", "⌃": modifiers |= UInt32(controlKey)
            case "comma": key = UInt32(kVK_ANSI_Comma)
            case "period", "dot": key = UInt32(kVK_ANSI_Period)
            default:
                let wanted = part.uppercased()
                if let match = names.first(where: { $0.value.uppercased() == wanted }) {
                    key = match.key
                } else {
                    return nil
                }
            }
        }
        guard let key, modifiers != 0 else { return nil }
        return Shortcut(keyCode: key, modifiers: modifiers)
    }
}
