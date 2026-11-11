import Foundation

/// A key combination, stored as a virtual key code so it works whatever the keyboard layout.
public struct KeyShortcut: Hashable, Sendable, Codable, CustomStringConvertible {
    public var keyCode: UInt16
    public var modifiers: ModifierSet

    public init(keyCode: UInt16, modifiers: ModifierSet = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// `⌃⌥⇧⌘T`, as macOS shows shortcuts in menus.
    public var displayString: String {
        modifiers.withoutFunction.symbols + KeyCodes.displayName(for: keyCode)
    }

    public var description: String { displayString }

    /// Flags to post with this shortcut: its modifiers plus the bits a real keyboard sets for the key itself.
    public var eventFlags: UInt64 {
        modifiers.eventFlags | KeyCodes.impliedFlags(for: keyCode)
    }

    /// Parses `"cmd+shift+t"`, `"⌘⇧T"`, `"control-left"` or `"F11"`. Returns nil for anything else.
    public init?(parsing text: String) {
        var rest = text.trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        var modifiers = ModifierSet()

        // Leading modifier symbols: ⌃⌥⇧⌘.
        let symbolMap: [Character: ModifierSet] = ["⌃": .control, "⌥": .option, "⇧": .shift, "⌘": .command]
        while let first = rest.first, let modifier = symbolMap[first], rest.count > 1 {
            modifiers.insert(modifier)
            rest.removeFirst()
        }

        // Word modifiers joined by + or -; the last part is the key. A lone "+" or "-" is a key.
        var parts = Self.split(rest)
        guard let keyName = parts.popLast(), !keyName.isEmpty else { return nil }
        for part in parts {
            guard let modifier = Self.modifierAliases[part.lowercased()] else { return nil }
            modifiers.insert(modifier)
        }
        guard let code = KeyCodes.keyCode(named: keyName) else { return nil }
        self.init(keyCode: code, modifiers: modifiers)
    }

    private static let modifierAliases: [String: ModifierSet] = [
        "cmd": .command, "command": .command, "⌘": .command,
        "opt": .option, "option": .option, "alt": .option, "⌥": .option,
        "ctrl": .control, "control": .control, "⌃": .control,
        "shift": .shift, "⇧": .shift,
        "fn": .function, "function": .function,
    ]

    private static func split(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        for character in text {
            if (character == "+" || character == "-"), !current.isEmpty {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

/// Virtual key codes of the ANSI keyboard (the values of the public `kVK_*` constants).
public enum KeyCodes {
    public struct Key: Sendable {
        public let code: UInt16
        public let name: String
        public let display: String
        public let aliases: [String]
        let implied: UInt64
    }

    private static let fn = ModifierSet.EventFlag.function
    private static let arrow = ModifierSet.EventFlag.function | ModifierSet.EventFlag.numericPad

    private static func letter(_ code: UInt16, _ name: String) -> Key {
        Key(code: code, name: name, display: name, aliases: [], implied: 0)
    }

    public static let all: [Key] = {
        var keys: [Key] = [
            letter(0x00, "A"), letter(0x01, "S"), letter(0x02, "D"), letter(0x03, "F"), letter(0x04, "H"),
            letter(0x05, "G"), letter(0x06, "Z"), letter(0x07, "X"), letter(0x08, "C"), letter(0x09, "V"),
            letter(0x0B, "B"), letter(0x0C, "Q"), letter(0x0D, "W"), letter(0x0E, "E"), letter(0x0F, "R"),
            letter(0x10, "Y"), letter(0x11, "T"), letter(0x12, "1"), letter(0x13, "2"), letter(0x14, "3"),
            letter(0x15, "4"), letter(0x16, "6"), letter(0x17, "5"), letter(0x19, "9"), letter(0x1A, "7"),
            letter(0x1C, "8"), letter(0x1D, "0"), letter(0x1F, "O"), letter(0x20, "U"), letter(0x22, "I"),
            letter(0x23, "P"), letter(0x25, "L"), letter(0x26, "J"), letter(0x28, "K"), letter(0x2D, "N"),
            letter(0x2E, "M"),
            Key(code: 0x18, name: "=", display: "=", aliases: ["equal", "equals", "plus"], implied: 0),
            Key(code: 0x1B, name: "-", display: "-", aliases: ["minus"], implied: 0),
            Key(code: 0x1E, name: "]", display: "]", aliases: ["rightbracket"], implied: 0),
            Key(code: 0x21, name: "[", display: "[", aliases: ["leftbracket"], implied: 0),
            Key(code: 0x27, name: "'", display: "'", aliases: ["quote"], implied: 0),
            Key(code: 0x29, name: ";", display: ";", aliases: ["semicolon"], implied: 0),
            Key(code: 0x2A, name: "\\", display: "\\", aliases: ["backslash"], implied: 0),
            Key(code: 0x2B, name: ",", display: ",", aliases: ["comma"], implied: 0),
            Key(code: 0x2C, name: "/", display: "/", aliases: ["slash"], implied: 0),
            Key(code: 0x2F, name: ".", display: ".", aliases: ["period"], implied: 0),
            Key(code: 0x32, name: "`", display: "`", aliases: ["grave", "backtick"], implied: 0),
            Key(code: 0x24, name: "Return", display: "↩", aliases: ["enter", "↩"], implied: 0),
            Key(code: 0x30, name: "Tab", display: "⇥", aliases: ["⇥"], implied: 0),
            Key(code: 0x31, name: "Space", display: "Space", aliases: ["spacebar"], implied: 0),
            Key(code: 0x33, name: "Delete", display: "⌫", aliases: ["backspace", "⌫"], implied: 0),
            Key(code: 0x35, name: "Escape", display: "⎋", aliases: ["esc", "⎋"], implied: 0),
            Key(code: 0x73, name: "Home", display: "↖", aliases: ["↖"], implied: fn),
            Key(code: 0x74, name: "Page Up", display: "⇞", aliases: ["pageup", "pgup", "⇞"], implied: fn),
            Key(code: 0x75, name: "Forward Delete", display: "⌦", aliases: ["forwarddelete", "⌦"], implied: fn),
            Key(code: 0x77, name: "End", display: "↘", aliases: ["↘"], implied: fn),
            Key(code: 0x79, name: "Page Down", display: "⇟", aliases: ["pagedown", "pgdn", "⇟"], implied: fn),
            Key(code: 0x7B, name: "Left", display: "←", aliases: ["leftarrow", "←"], implied: arrow),
            Key(code: 0x7C, name: "Right", display: "→", aliases: ["rightarrow", "→"], implied: arrow),
            Key(code: 0x7D, name: "Down", display: "↓", aliases: ["downarrow", "↓"], implied: arrow),
            Key(code: 0x7E, name: "Up", display: "↑", aliases: ["uparrow", "↑"], implied: arrow),
        ]
        let functionKeys: [UInt16] = [
            0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D,
            0x67, 0x6F, 0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A,
        ]
        for (index, code) in functionKeys.enumerated() {
            keys.append(Key(code: code, name: "F\(index + 1)", display: "F\(index + 1)", aliases: [], implied: fn))
        }
        return keys
    }()

    private static let byCode: [UInt16: Key] = Dictionary(all.map { ($0.code, $0) }, uniquingKeysWith: { first, _ in first })

    private static let byName: [String: UInt16] = {
        var map: [String: UInt16] = [:]
        for key in all {
            for name in [key.name, key.display] + key.aliases {
                map[normalise(name)] = map[normalise(name)] ?? key.code
            }
        }
        return map
    }()

    private static func normalise(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: " ", with: "")
    }

    public static func key(for code: UInt16) -> Key? { byCode[code] }

    public static func keyCode(named name: String) -> UInt16? { byName[normalise(name)] }

    public static func displayName(for code: UInt16) -> String {
        byCode[code]?.display ?? "Key \(code)"
    }

    public static func name(for code: UInt16) -> String {
        byCode[code]?.name ?? "Key \(code)"
    }

    /// Bits a hardware keyboard sets alongside some keys (fn for F-keys and navigation keys, fn and
    /// numeric pad for the arrows). System shortcuts are matched with these included.
    public static func impliedFlags(for code: UInt16) -> UInt64 {
        byCode[code]?.implied ?? 0
    }
}
