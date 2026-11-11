import Foundation

/// The modifier keys a mapping can require or a synthetic event can carry.
///
/// Stored in settings as an array of names (`["control", "command"]`) so the file stays readable.
public struct ModifierSet: OptionSet, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let function = ModifierSet(rawValue: 1 << 0)
    public static let control = ModifierSet(rawValue: 1 << 1)
    public static let option = ModifierSet(rawValue: 1 << 2)
    public static let shift = ModifierSet(rawValue: 1 << 3)
    public static let command = ModifierSet(rawValue: 1 << 4)

    /// Display order used by macOS menus: fn ⌃ ⌥ ⇧ ⌘.
    public static let ordered: [(modifier: ModifierSet, name: String, symbol: String, title: String)] = [
        (.function, "function", "fn", "Function"),
        (.control, "control", "⌃", "Control"),
        (.option, "option", "⌥", "Option"),
        (.shift, "shift", "⇧", "Shift"),
        (.command, "command", "⌘", "Command"),
    ]

    /// Bit masks of `CGEventFlags` / `NSEvent.ModifierFlags`.
    public enum EventFlag {
        public static let shift: UInt64 = 0x0002_0000
        public static let control: UInt64 = 0x0004_0000
        public static let option: UInt64 = 0x0008_0000
        public static let command: UInt64 = 0x0010_0000
        public static let numericPad: UInt64 = 0x0020_0000
        public static let function: UInt64 = 0x0080_0000
    }

    private static let flagPairs: [(ModifierSet, UInt64)] = [
        (.shift, EventFlag.shift), (.control, EventFlag.control), (.option, EventFlag.option),
        (.command, EventFlag.command), (.function, EventFlag.function),
    ]

    /// Reads the modifiers out of raw event flags, ignoring every other bit.
    public init(eventFlags: UInt64) {
        var set = ModifierSet()
        for (modifier, mask) in Self.flagPairs where eventFlags & mask != 0 { set.insert(modifier) }
        self = set
    }

    /// The event flag bits for these modifiers.
    public var eventFlags: UInt64 {
        Self.flagPairs.reduce(0) { contains($1.0) ? $0 | $1.1 : $0 }
    }

    /// The modifiers without the function key, which mice and most shortcuts ignore.
    public var withoutFunction: ModifierSet { subtracting(.function) }

    /// `⌃⌥⇧⌘`, in menu order.
    public var symbols: String {
        Self.ordered.filter { contains($0.modifier) }.map(\.symbol).joined()
    }

    public var names: [String] {
        Self.ordered.filter { contains($0.modifier) }.map(\.name)
    }

    public var description: String { symbols }

    public init?(name: String) {
        guard let entry = Self.ordered.first(where: { $0.name == name.lowercased() }) else { return nil }
        self = entry.modifier
    }
}

extension ModifierSet: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let names = try container.decode([String].self)
        var set = ModifierSet()
        for name in names {
            guard let modifier = ModifierSet(name: name) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown modifier “\(name)”.")
            }
            set.insert(modifier)
        }
        self = set
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(names)
    }
}
