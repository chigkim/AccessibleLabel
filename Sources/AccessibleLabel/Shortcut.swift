import AppKit
import Carbon.HIToolbox

struct Shortcut: Codable, Equatable {
    var keyCode: UInt16
    /// Raw value of `NSEvent.ModifierFlags` (device-independent bits only).
    var modifiers: UInt
    /// Human-readable key, captured when the shortcut was recorded.
    var keyLabel: String

    static let relevantModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    static let `default` = Shortcut(
        keyCode: UInt16(kVK_Escape),
        modifiers: NSEvent.ModifierFlags.control.rawValue,
        keyLabel: "Esc"
    )

    init(keyCode: UInt16, modifiers: UInt, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    init(event: NSEvent) {
        keyCode = event.keyCode
        modifiers = event.modifierFlags.intersection(Self.relevantModifiers).rawValue
        keyLabel = Self.label(for: event)
    }

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if modifierFlags.contains(.command) { result |= UInt32(cmdKey) }
        if modifierFlags.contains(.option) { result |= UInt32(optionKey) }
        if modifierFlags.contains(.control) { result |= UInt32(controlKey) }
        if modifierFlags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    var displayString: String {
        var s = ""
        if modifierFlags.contains(.control) { s += "⌃" }
        if modifierFlags.contains(.option) { s += "⌥" }
        if modifierFlags.contains(.shift) { s += "⇧" }
        if modifierFlags.contains(.command) { s += "⌘" }
        // Prefer the current name for special keys so older saved labels (e.g. "⎋") display consistently.
        return s + (Self.specialKeys[Int(keyCode)] ?? keyLabel)
    }

    /// VoiceOver captures every ⌃⌥ combination while it's running.
    var conflictsWithVoiceOver: Bool { modifierFlags.isSuperset(of: [.control, .option]) }

    static func isFunctionKey(_ keyCode: UInt16) -> Bool {
        specialKeys[Int(keyCode)]?.hasPrefix("F") == true
    }

    private static let specialKeys: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "Esc", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    private static func label(for event: NSEvent) -> String {
        if let special = specialKeys[Int(event.keyCode)] { return special }
        let chars = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? "?"
        return chars.uppercased()
    }

    // MARK: Persistence

    private static let defaultsKey = "shortcut"

    static func load() -> Shortcut {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let shortcut = try? JSONDecoder().decode(Shortcut.self, from: data)
        else { return .default }
        return shortcut
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
