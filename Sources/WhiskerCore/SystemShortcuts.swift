import Foundation

/// System keyboard shortcuts (System Settings › Keyboard › Keyboard Shortcuts) that some actions post.
/// The numbers are the keys of `AppleSymbolicHotKeys` in the `com.apple.symbolichotkeys` defaults domain.
public enum SystemShortcutID: Int, CaseIterable, Sendable {
    case missionControl = 32
    case applicationWindows = 33
    case showDesktop = 36
    case spotlight = 64
    case moveLeftSpace = 79
    case moveRightSpace = 81
    case launchpad = 160
    case notificationCentre = 163

    public var title: String {
        switch self {
        case .missionControl: return "Mission Control"
        case .applicationWindows: return "Application windows"
        case .showDesktop: return "Show Desktop"
        case .spotlight: return "Show Spotlight search"
        case .moveLeftSpace: return "Move left a space"
        case .moveRightSpace: return "Move right a space"
        case .launchpad: return "Show Launchpad"
        case .notificationCentre: return "Show Notification Centre"
        }
    }

    /// The binding macOS uses when the user has never changed the shortcut (no entry in the domain).
    public var factoryDefault: SystemShortcutStatus {
        switch self {
        case .missionControl: return .available(KeyShortcut(keyCode: 0x7E, modifiers: .control))
        case .applicationWindows: return .available(KeyShortcut(keyCode: 0x7D, modifiers: .control))
        case .showDesktop: return .available(KeyShortcut(keyCode: 0x67))
        case .spotlight: return .available(KeyShortcut(keyCode: 0x31, modifiers: .command))
        case .moveLeftSpace: return .available(KeyShortcut(keyCode: 0x7B, modifiers: .control))
        case .moveRightSpace: return .available(KeyShortcut(keyCode: 0x7C, modifiers: .control))
        case .launchpad, .notificationCentre: return .unassigned
        }
    }
}

public enum SystemShortcutStatus: Equatable, Sendable {
    case available(KeyShortcut)
    /// The shortcut exists but its checkbox is off.
    case disabled
    /// No key is assigned.
    case unassigned

    public var shortcut: KeyShortcut? {
        if case .available(let shortcut) = self { return shortcut }
        return nil
    }
}

/// Where the current system shortcuts come from. The app reads the user's defaults; tests supply a table.
public protocol SystemShortcutProviding: Sendable {
    func status(of id: SystemShortcutID) -> SystemShortcutStatus
}

/// The parsed `AppleSymbolicHotKeys` dictionary.
public struct SymbolicHotKeyTable: SystemShortcutProviding, Equatable {
    public private(set) var entries: [Int: SystemShortcutStatus]

    public init(entries: [Int: SystemShortcutStatus] = [:]) {
        self.entries = entries
    }

    /// Parses the value of `AppleSymbolicHotKeys`: `{"32": {"enabled": 1, "value": {"parameters": [char, keyCode, flags]}}}`.
    /// Entries that are missing or malformed fall back to the factory default.
    public init(dictionary: [String: Any]?) {
        var entries: [Int: SystemShortcutStatus] = [:]
        for (key, raw) in dictionary ?? [:] {
            guard let id = Int(key), let entry = raw as? [String: Any] else { continue }
            if let status = Self.parse(entry) { entries[id] = status }
        }
        self.entries = entries
    }

    static func parse(_ entry: [String: Any]) -> SystemShortcutStatus? {
        let enabled = (entry["enabled"] as? NSNumber)?.boolValue ?? (entry["enabled"] as? Bool) ?? false
        guard enabled else { return .disabled }
        guard let value = entry["value"] as? [String: Any],
              let parameters = value["parameters"] as? [Any], parameters.count >= 3,
              let keyCode = (parameters[1] as? NSNumber)?.intValue,
              let flags = (parameters[2] as? NSNumber)?.uint64Value
        else { return nil }
        guard keyCode >= 0, keyCode < 0xFFFF else { return .unassigned }
        return .available(KeyShortcut(keyCode: UInt16(keyCode), modifiers: ModifierSet(eventFlags: flags)))
    }

    public func status(of id: SystemShortcutID) -> SystemShortcutStatus {
        entries[id.rawValue] ?? id.factoryDefault
    }
}
