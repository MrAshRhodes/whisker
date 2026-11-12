import Foundation

/// The whole settings file (`~/Library/Application Support/Whisker/settings.json`).
public struct WhiskerSettings: Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var general: GeneralSettings
    /// Per-device settings keyed by `DeviceIdentity.id`.
    public var devices: [String: DeviceSettings]
    /// The first profile with id `default` is the global profile; the rest are per app or per device.
    public var profiles: [Profile]
    /// Top-level keys this version doesn't know, kept so a newer file survives a round trip.
    public var unknownKeys: [String: JSONValue]

    public init(
        schemaVersion: Int = WhiskerSettings.currentSchemaVersion,
        general: GeneralSettings = GeneralSettings(),
        devices: [String: DeviceSettings] = [:],
        profiles: [Profile] = [.makeDefault()],
        unknownKeys: [String: JSONValue] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.general = general
        self.devices = devices
        self.profiles = profiles
        self.unknownKeys = unknownKeys
    }

    public static let `default` = WhiskerSettings()

    public var defaultProfile: Profile {
        profiles.first { $0.id == Profile.defaultID } ?? .makeDefault()
    }

    public func profile(id: String) -> Profile? {
        profiles.first { $0.id == id }
    }

    /// Replaces the profile with the same id, or appends it.
    public mutating func upsert(_ profile: Profile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
    }

    public func device(_ id: String) -> DeviceSettings {
        devices[id] ?? DeviceSettings()
    }

    /// The profile used for one app on every device, if there is one.
    /// The pointer settings Whisker should have applied to a device right now: none while Whisker or the
    /// device is switched off, so the system's own settings come back.
    public func activePointer(for deviceID: String) -> PointerSettings? {
        guard general.enabled, let device = devices[deviceID], device.enabled else { return nil }
        return device.pointer
    }

    public func appProfile(bundleID: String) -> Profile? {
        profiles.first { $0.id != Profile.defaultID && $0.match.apps == [bundleID] && $0.match.devices == [ProfileMatch.any] }
    }

    /// The profile used for one device in every app, if there is one.
    public func deviceProfile(deviceID: String) -> Profile? {
        profiles.first { $0.id != Profile.defaultID && $0.match.devices == [deviceID] && $0.match.apps == [ProfileMatch.any] }
    }
}

public struct GeneralSettings: Equatable, Sendable {
    /// Master switch: off means every event passes through untouched.
    public var enabled: Bool
    public var showMenuBarIcon: Bool
    /// The primary button without modifiers can't be remapped unless this is on, so a bad mapping can't lock you out.
    public var allowPrimaryButtonRemap: Bool
    /// Bundle identifiers of apps Whisker stands aside for. While one is in front, button mappings, wheel
    /// actions, scroll changes and pointer overrides all switch off as if Whisker were off. It never turns
    /// Whisker on: the master switch still wins.
    public var bypassApps: [String]

    public init(enabled: Bool = true, showMenuBarIcon: Bool = true, allowPrimaryButtonRemap: Bool = false, bypassApps: [String] = []) {
        self.enabled = enabled
        self.showMenuBarIcon = showMenuBarIcon
        self.allowPrimaryButtonRemap = allowPrimaryButtonRemap
        self.bypassApps = bypassApps
    }
}

public struct DeviceSettings: Equatable, Sendable {
    /// Display name remembered from the device, so settings for an unplugged mouse still read well.
    public var name: String
    /// Off means Whisker leaves this device alone.
    public var enabled: Bool
    /// `nil` keeps the system pointer speed.
    public var pointer: PointerSettings?
    public var wheel: WheelSettings

    public init(name: String = "", enabled: Bool = true, pointer: PointerSettings? = nil, wheel: WheelSettings = WheelSettings()) {
        self.name = name
        self.enabled = enabled
        self.pointer = pointer
        self.wheel = wheel
    }
}

public struct PointerSettings: Equatable, Sendable {
    /// Multiplier of the device's normal speed, `PointerMath.speedRange`.
    public var speed: Double
    /// Acceleration, `PointerMath.accelerationRange`; ignored when `linear`.
    public var acceleration: Double
    /// No acceleration: the pointer moves the same distance whatever the hand speed.
    public var linear: Bool

    public init(speed: Double = 1, acceleration: Double = 0.6875, linear: Bool = false) {
        self.speed = speed
        self.acceleration = acceleration
        self.linear = linear
    }
}

public struct WheelSettings: Equatable, Sendable {
    public var invertVertical: Bool
    public var invertHorizontal: Bool

    public init(invertVertical: Bool = false, invertHorizontal: Bool = false) {
        self.invertVertical = invertVertical
        self.invertHorizontal = invertHorizontal
    }
}

/// Wheel behaviour a profile can set (event mode, applied in the event tap).
public struct ScrollSettings: Equatable, Sendable {
    /// Lines per wheel notch, `ScrollMath.linesRange`; nil keeps the system distance.
    public var linesPerNotch: Int?
    /// How much faster quick spins scroll, `ScrollMath.accelerationRange`; only used with `linesPerNotch`.
    public var acceleration: Double
    /// Holding these turns vertical wheel movement into horizontal scrolling. Empty = off.
    public var horizontalModifier: ModifierSet
    /// Scales the distance while modifiers are held. Nil = off.
    public var modifierScaling: ModifierScaling?

    public init(
        linesPerNotch: Int? = nil,
        acceleration: Double = 0,
        horizontalModifier: ModifierSet = [],
        modifierScaling: ModifierScaling? = nil
    ) {
        self.linesPerNotch = linesPerNotch
        self.acceleration = acceleration
        self.horizontalModifier = horizontalModifier
        self.modifierScaling = modifierScaling
    }

    public static let system = ScrollSettings()

    /// `modifierScaling` when it can be used, otherwise nil: the wheel then behaves as if scaling were off.
    var usableModifierScaling: ModifierScaling? {
        guard let scaling = modifierScaling, scaling.problem(horizontalModifier: horizontalModifier) == nil else { return nil }
        return scaling
    }
}

/// Which wheel directions a `ModifierScaling` changes. Directions are those the app receives, after the
/// sideways modifier has turned up and down into left and right.
public enum ScalingAxes: String, Equatable, Sendable, Codable, CaseIterable {
    case both
    case vertical
    case horizontal

    public var includesVertical: Bool { self != .horizontal }
    public var includesHorizontal: Bool { self != .vertical }
}

/// Makes the wheel scroll further or less far while modifiers are held, e.g. half the distance for fine control.
/// Pointer speed and clicking are not affected.
public struct ModifierScaling: Equatable, Sendable {
    /// Holding these scales the wheel. Must not be empty, nor the same as the sideways modifier.
    public var modifiers: ModifierSet
    /// Multiplier of the distance, `ScrollMath.multiplierRange`: below 1 slows the wheel, above 1 speeds it up.
    public var multiplier: Double
    public var axes: ScalingAxes

    public init(modifiers: ModifierSet = [], multiplier: Double = 2, axes: ScalingAxes = .both) {
        self.modifiers = modifiers
        self.multiplier = multiplier
        self.axes = axes
    }

    /// Why this can't be used next to the sideways modifier, or nil when it is fine. Shared by validation, the
    /// settings window and the event processor, which leaves scaling with a problem switched off.
    public func problem(horizontalModifier: ModifierSet) -> String? {
        let held = modifiers.withoutFunction
        if held.isEmpty { return "Choose at least one modifier key to hold." }
        if held == horizontalModifier.withoutFunction {
            return "\(held.symbols) already scrolls sideways. Choose a different modifier for the speed."
        }
        if !multiplier.isFinite || multiplier <= 0 { return "The speed must be more than zero." }
        return nil
    }
}

public struct ProfileMatch: Equatable, Sendable, Codable {
    public static let any = "*"

    /// Device ids, or `*` for every device.
    public var devices: [String]
    /// Bundle identifiers, or `*` for every app.
    public var apps: [String]

    public init(devices: [String] = [ProfileMatch.any], apps: [String] = [ProfileMatch.any]) {
        self.devices = devices
        self.apps = apps
    }
}

public struct Profile: Equatable, Sendable, Identifiable {
    public static let defaultID = "default"

    public var id: String
    public var name: String
    public var match: ProfileMatch
    /// Profile whose mappings and scroll settings fill in what this one leaves out. Nil = start from nothing.
    public var inherits: String?
    /// Nil inherits the parent's scroll settings.
    public var scroll: ScrollSettings?
    public var mappings: [Mapping]

    public init(
        id: String = UUID().uuidString.lowercased(),
        name: String,
        match: ProfileMatch = ProfileMatch(),
        inherits: String? = Profile.defaultID,
        scroll: ScrollSettings? = nil,
        mappings: [Mapping] = []
    ) {
        self.id = id
        self.name = name
        self.match = match
        self.inherits = id == Profile.defaultID ? nil : inherits
        self.scroll = scroll
        self.mappings = mappings
    }

    public var isDefault: Bool { id == Self.defaultID }

    /// The global profile a fresh install starts with: the side buttons go back and forward.
    public static func makeDefault() -> Profile {
        Profile(
            id: defaultID,
            name: "Default",
            mappings: [
                Mapping(trigger: .button(3), action: .navigate(.back)),
                Mapping(trigger: .button(4), action: .navigate(.forward)),
            ]
        )
    }

    public static func forApp(bundleID: String, name: String) -> Profile {
        Profile(name: name, match: ProfileMatch(devices: [ProfileMatch.any], apps: [bundleID]))
    }

    public static func forDevice(id deviceID: String, name: String) -> Profile {
        Profile(name: name, match: ProfileMatch(devices: [deviceID], apps: [ProfileMatch.any]))
    }

    public func mapping(for key: MappingKey) -> Mapping? {
        mappings.first { $0.key == key }
    }
}

public struct MappingKey: Hashable, Sendable {
    public var trigger: Trigger
    public var modifiers: ModifierSet

    public init(_ trigger: Trigger, _ modifiers: ModifierSet = []) {
        self.trigger = trigger
        self.modifiers = modifiers
    }

    public var title: String {
        modifiers.isEmpty ? trigger.title : "\(modifiers.symbols) \(trigger.title)"
    }
}

public struct Mapping: Equatable, Sendable {
    public var trigger: Trigger
    /// Modifier keys that must be held, exactly, for this mapping to apply.
    public var modifiers: ModifierSet
    public var action: Action
    /// Wheel triggers only: fire on every notch instead of once per burst of notches.
    public var repeatPerNotch: Bool
    /// Scroll Left/Right only: nil acts on discrete notches alone; otherwise a mouse's smooth horizontal
    /// scrolling also fires the action once per burst, leaving any vertical movement alone.
    public var continuousInput: ContinuousWheelInput?

    public init(trigger: Trigger, modifiers: ModifierSet = [], action: Action, repeatPerNotch: Bool = false, continuousInput: ContinuousWheelInput? = nil) {
        self.trigger = trigger
        self.modifiers = modifiers
        self.action = action
        self.repeatPerNotch = repeatPerNotch
        self.continuousInput = continuousInput
    }

    public var key: MappingKey { MappingKey(trigger, modifiers) }
}

// MARK: - Coding

extension GeneralSettings: Codable {
    private enum CodingKeys: String, CodingKey { case enabled, showMenuBarIcon, allowPrimaryButtonRemap, bypassApps }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = GeneralSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        showMenuBarIcon = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarIcon) ?? defaults.showMenuBarIcon
        allowPrimaryButtonRemap = try c.decodeIfPresent(Bool.self, forKey: .allowPrimaryButtonRemap) ?? defaults.allowPrimaryButtonRemap
        bypassApps = try c.decodeIfPresent([String].self, forKey: .bypassApps) ?? defaults.bypassApps
    }
}

extension DeviceSettings: Codable {
    private enum CodingKeys: String, CodingKey { case name, enabled, pointer, wheel }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        pointer = try c.decodeIfPresent(PointerSettings.self, forKey: .pointer)
        wheel = try c.decodeIfPresent(WheelSettings.self, forKey: .wheel) ?? WheelSettings()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(enabled, forKey: .enabled)
        try c.encodeIfPresent(pointer, forKey: .pointer)
        try c.encode(wheel, forKey: .wheel)
    }
}

extension PointerSettings: Codable {
    private enum CodingKeys: String, CodingKey { case speed, acceleration, linear }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PointerSettings()
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? defaults.speed
        acceleration = try c.decodeIfPresent(Double.self, forKey: .acceleration) ?? defaults.acceleration
        linear = try c.decodeIfPresent(Bool.self, forKey: .linear) ?? defaults.linear
    }
}

extension WheelSettings: Codable {
    private enum CodingKeys: String, CodingKey { case invertVertical, invertHorizontal }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        invertVertical = try c.decodeIfPresent(Bool.self, forKey: .invertVertical) ?? false
        invertHorizontal = try c.decodeIfPresent(Bool.self, forKey: .invertHorizontal) ?? false
    }
}

extension ScrollSettings: Codable {
    private enum CodingKeys: String, CodingKey { case linesPerNotch, acceleration, horizontalModifier, modifierScaling }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        linesPerNotch = try c.decodeIfPresent(Int.self, forKey: .linesPerNotch)
        acceleration = try c.decodeIfPresent(Double.self, forKey: .acceleration) ?? 0
        horizontalModifier = try c.decodeIfPresent(ModifierSet.self, forKey: .horizontalModifier) ?? []
        modifierScaling = try c.decodeIfPresent(ModifierScaling.self, forKey: .modifierScaling)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(linesPerNotch, forKey: .linesPerNotch)
        try c.encode(acceleration, forKey: .acceleration)
        try c.encode(horizontalModifier, forKey: .horizontalModifier)
        try c.encodeIfPresent(modifierScaling, forKey: .modifierScaling)
    }
}

extension ModifierScaling: Codable {
    private enum CodingKeys: String, CodingKey { case modifiers, multiplier, axes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ModifierScaling()
        modifiers = try c.decodeIfPresent(ModifierSet.self, forKey: .modifiers) ?? defaults.modifiers
        multiplier = try c.decodeIfPresent(Double.self, forKey: .multiplier) ?? defaults.multiplier
        axes = try c.decodeIfPresent(ScalingAxes.self, forKey: .axes) ?? defaults.axes
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(modifiers, forKey: .modifiers)
        try c.encode(multiplier, forKey: .multiplier)
        try c.encode(axes, forKey: .axes)
    }
}

extension Profile: Codable {
    private enum CodingKeys: String, CodingKey { case id, name, match, inherits, scroll, mappings }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        match = try c.decodeIfPresent(ProfileMatch.self, forKey: .match) ?? ProfileMatch()
        // A missing "inherits" means the default profile; an explicit null means no parent.
        if id == Profile.defaultID {
            inherits = nil
        } else if c.contains(.inherits) {
            inherits = try c.decodeNil(forKey: .inherits) ? nil : try c.decode(String.self, forKey: .inherits)
        } else {
            inherits = Profile.defaultID
        }
        scroll = try c.decodeIfPresent(ScrollSettings.self, forKey: .scroll)
        mappings = try c.decodeIfPresent([Mapping].self, forKey: .mappings) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(match, forKey: .match)
        if !isDefault {
            if let inherits { try c.encode(inherits, forKey: .inherits) } else { try c.encodeNil(forKey: .inherits) }
        }
        if let scroll { try c.encode(scroll, forKey: .scroll) } else { try c.encodeNil(forKey: .scroll) }
        try c.encode(mappings, forKey: .mappings)
    }
}

extension Mapping: Codable {
    private enum CodingKeys: String, CodingKey { case trigger, modifiers, action, repeatPerNotch, continuousInput }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trigger = try c.decode(Trigger.self, forKey: .trigger)
        modifiers = try c.decodeIfPresent(ModifierSet.self, forKey: .modifiers) ?? []
        action = try c.decode(Action.self, forKey: .action)
        repeatPerNotch = try c.decodeIfPresent(Bool.self, forKey: .repeatPerNotch) ?? false
        continuousInput = try c.decodeIfPresent(ContinuousWheelInput.self, forKey: .continuousInput)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(trigger, forKey: .trigger)
        try c.encode(modifiers, forKey: .modifiers)
        try c.encode(action, forKey: .action)
        if repeatPerNotch { try c.encode(true, forKey: .repeatPerNotch) }
        if let continuousInput { try c.encode(continuousInput, forKey: .continuousInput) }
    }
}

extension ContinuousWheelInput: Codable {
    private enum CodingKeys: String, CodingKey { case distance }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        distance = try c.decodeIfPresent(Double.self, forKey: .distance) ?? Self.defaultDistance
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(distance, forKey: .distance)
    }
}

extension WhiskerSettings: Codable {
    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    private static let knownKeys: Set<String> = ["schemaVersion", "general", "devices", "profiles"]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: Key("schemaVersion")) ?? 0
        general = try c.decodeIfPresent(GeneralSettings.self, forKey: Key("general")) ?? GeneralSettings()
        devices = try c.decodeIfPresent([String: DeviceSettings].self, forKey: Key("devices")) ?? [:]
        profiles = try c.decodeIfPresent([Profile].self, forKey: Key("profiles")) ?? [.makeDefault()]
        var unknown: [String: JSONValue] = [:]
        for key in c.allKeys where !Self.knownKeys.contains(key.stringValue) {
            unknown[key.stringValue] = try c.decode(JSONValue.self, forKey: key)
        }
        unknownKeys = unknown
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        for (key, value) in unknownKeys where !Self.knownKeys.contains(key) {
            try c.encode(value, forKey: Key(key))
        }
        try c.encode(schemaVersion, forKey: Key("schemaVersion"))
        try c.encode(general, forKey: Key("general"))
        try c.encode(devices, forKey: Key("devices"))
        try c.encode(profiles, forKey: Key("profiles"))
    }
}

/// Any JSON value, for keys Whisker passes through without understanding.
public enum JSONValue: Equatable, Sendable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let value = try? c.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? c.decode(Double.self) {
            self = .number(value)
        } else if let value = try? c.decode(String.self) {
            self = .string(value)
        } else if let value = try? c.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let value): try c.encode(value)
        case .number(let value): try c.encode(value)
        case .string(let value): try c.encode(value)
        case .array(let value): try c.encode(value)
        case .object(let value): try c.encode(value)
        }
    }
}
