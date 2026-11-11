import Foundation

public enum WheelDirection: String, Codable, CaseIterable, Sendable {
    case up, down, left, right

    public var title: String {
        switch self {
        case .up: return "Scroll Up"
        case .down: return "Scroll Down"
        case .left: return "Scroll Left"
        case .right: return "Scroll Right"
        }
    }

    public var symbolName: String {
        switch self {
        case .up: return "arrow.up"
        case .down: return "arrow.down"
        case .left: return "arrow.left"
        case .right: return "arrow.right"
        }
    }

    public var isVertical: Bool { self == .up || self == .down }
}

/// What the user does with the mouse to set off a mapping.
public enum Trigger: Hashable, Sendable {
    /// Mouse button by event number: 0 primary, 1 secondary, 2 middle, 3 and up the extra buttons.
    case button(Int)
    /// One notch of the wheel in a direction.
    case wheel(WheelDirection)

    public static let buttonRange = 0...31

    public var title: String {
        switch self {
        case .button(let number): return Self.buttonTitle(number)
        case .wheel(let direction): return direction.title
        }
    }

    public var symbolName: String {
        switch self {
        case .button: return "computermouse"
        case .wheel(let direction): return direction.symbolName
        }
    }

    public static func buttonTitle(_ number: Int) -> String {
        switch number {
        case 0: return "Primary Button"
        case 1: return "Secondary Button"
        case 2: return "Middle Button"
        default: return "Button \(number + 1)"
        }
    }

    var sortKey: Int {
        switch self {
        case .button(let number): return number
        case .wheel(let direction): return 100 + (WheelDirection.allCases.firstIndex(of: direction) ?? 0)
        }
    }
}

extension Trigger: Codable {
    private enum CodingKeys: String, CodingKey { case type, button, direction }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "button": self = .button(try container.decode(Int.self, forKey: .button))
        case "wheel": self = .wheel(try container.decode(WheelDirection.self, forKey: .direction))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown trigger type “\(other)”.")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .button(let number):
            try container.encode("button", forKey: .type)
            try container.encode(number, forKey: .button)
        case .wheel(let direction):
            try container.encode("wheel", forKey: .type)
            try container.encode(direction, forKey: .direction)
        }
    }
}
