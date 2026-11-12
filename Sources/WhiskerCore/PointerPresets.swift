import Foundation

/// A named software pointer speed saved for one device: the same multiplier as `PointerSettings.speed`.
/// Presets never touch acceleration or linear movement, and say nothing about the mouse's own DPI.
public struct PointerPreset: Equatable, Sendable, Identifiable {
    public static let maxNameLength = 40
    /// Keeps the menu short and the settings file tidy.
    public static let maxPerDevice = 12
    public static let defaultName = "Preset"

    /// Stable, so a Buttons mapping keeps pointing at the preset when it is renamed or moved.
    public var id: String
    public var name: String
    /// Multiplier of the device's normal speed, `PointerMath.speedRange`.
    public var speed: Double

    public init(id: String = UUID().uuidString.lowercased(), name: String, speed: Double) {
        self.id = id
        self.name = name
        self.speed = speed
    }

    /// "Fast — ×1.5", the way the preset reads in lists and menus.
    public var label: String { "\(name) — \(PointerMath.speedLabel(speed))" }

    /// One line of text of at most `maxNameLength` characters, or empty when nothing usable is left.
    public static func cleanedName(_ name: String) -> String {
        let oneLine = name.components(separatedBy: .newlines).joined(separator: " ")
        let trimmed = oneLine.trimmingCharacters(in: .whitespaces)
        return String(trimmed.prefix(maxNameLength)).trimmingCharacters(in: .whitespaces)
    }
}

extension PointerPreset: Codable {
    private enum CodingKeys: String, CodingKey { case id, name, speed }

    /// Tolerant like the rest of the file: a preset missing a field decodes, and validation then repairs or drops it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1
    }
}

extension PointerMath {
    /// A speed multiplier as people read it: "×1.5", "×2", "×0.25".
    public static func speedLabel(_ speed: Double) -> String {
        var text = String(format: "%.2f", speedRange.clamp(speed))
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return "×" + text
    }
}

/// A device's pointer speed together with the preset it came from: everything a confirmation has to put
/// back when a switch is reverted.
public struct PointerSelection: Equatable, Sendable {
    /// Nil is the system's own speed.
    public var pointer: PointerSettings?
    public var presetID: String?

    public init(pointer: PointerSettings?, presetID: String? = nil) {
        self.pointer = pointer
        self.presetID = presetID
    }

    public static let system = PointerSelection(pointer: nil)
}

/// Why a switch to a preset can't go ahead. Nothing is changed when one of these applies.
public enum PointerPresetRefusal: Equatable, Sendable {
    /// Another speed change is waiting to be kept or reverted.
    case confirmationPending
    /// An app on the bypass list is in front, so pointer speed is left to the system until it leaves.
    case appBypassed
    case whiskerOff
    case unknownDevice
    case deviceOff
    case customSpeedOff
    case unknownPreset
    case notConnected
    /// Identical mice can't be told apart, so a change could land on the wrong one.
    case ambiguousDevice
    case excludedDevice
    /// The system refused the new speed (or only part of it); the previous speed was put back.
    case hardwareRefused
    /// The previous speed couldn't be put back: after a refused switch, a revert, or a return to the system's speed.
    case restoreFailed
    /// A change that has to be kept couldn't be written down first, so it wasn't applied: a crash could have
    /// left it in use without anything on record to undo it.
    case trialNotRecorded

    public func message(device: String) -> String {
        let name = device.isEmpty ? "this mouse" : device
        switch self {
        case .confirmationPending: return "A speed change is still in progress. Keep or revert it first."
        case .appBypassed: return "Whisker is bypassed for the app in front, so pointer speed is left to the system."
        case .whiskerOff: return "Whisker is switched off, so pointer speed is left to the system."
        case .unknownDevice: return "Whisker doesn’t know this mouse."
        case .deviceOff: return "Whisker is switched off for \(name)."
        case .customSpeedOff: return "Turn on custom pointer speed for \(name) to switch presets."
        case .unknownPreset: return "That preset no longer exists."
        case .notConnected: return "\(name) isn’t connected."
        case .ambiguousDevice: return "More than one mouse of the same model is connected, so Whisker can’t tell which one to change."
        case .excludedDevice: return "Whisker leaves \(name) alone."
        case .hardwareRefused: return "The system refused the new speed for \(name). The previous speed was put back."
        case .restoreFailed: return "The system wouldn’t put the previous speed back for \(name). Whisker keeps the original values and will try again."
        case .trialNotRecorded: return "Whisker couldn’t save a recovery record for the new speed, so \(name) keeps its speed. Check that Whisker can write to its Application Support folder."
        }
    }
}

extension DeviceSettings {
    public func pointerPreset(id: String) -> PointerPreset? {
        pointerPresets.first { $0.id == id }
    }

    /// Speed and preset together, to remember and restore as one.
    public var pointerSelection: PointerSelection {
        get { PointerSelection(pointer: pointer, presetID: activePointerPresetID) }
        set {
            pointer = newValue.pointer
            activePointerPresetID = newValue.presetID
        }
    }

    /// The preset in use: the active one, while a custom speed is on and still matches the preset's speed.
    public var activePointerPreset: PointerPreset? {
        guard let pointer, let id = activePointerPresetID, let preset = pointerPreset(id: id),
              abs(preset.speed - pointer.speed) < 0.000_001 else { return nil }
        return preset
    }

    /// "Fast — ×1.5" while a preset is in use, "Custom" for any other custom speed, nil while the system speed is in use.
    public var pointerSpeedLabel: String? {
        guard pointer != nil else { return nil }
        return activePointerPreset?.label ?? "Custom"
    }

    /// `name` cleaned up and made different from every other preset's name (ignoring case).
    func uniquePresetName(_ name: String, excluding id: String? = nil) -> String {
        let cleaned = PointerPreset.cleanedName(name)
        let base = cleaned.isEmpty ? PointerPreset.defaultName : cleaned
        let taken = Set(pointerPresets.filter { $0.id != id }.map { $0.name.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var number = 2
        while true {
            let suffix = " \(number)"
            let candidate = String(base.prefix(PointerPreset.maxNameLength - suffix.count)) + suffix
            if !taken.contains(candidate.lowercased()) { return candidate }
            number += 1
        }
    }

    /// Saves the current custom speed as a new preset and makes it the active one. Nil when no custom speed
    /// is on or the list is full.
    @discardableResult
    public mutating func savePointerPreset(named name: String, id: String = UUID().uuidString.lowercased()) -> PointerPreset? {
        guard let pointer, pointerPresets.count < PointerPreset.maxPerDevice else { return nil }
        let preset = PointerPreset(id: id, name: uniquePresetName(name), speed: PointerMath.speedRange.clamp(pointer.speed))
        pointerPresets.append(preset)
        activePointerPresetID = preset.id
        return preset
    }

    /// False when the preset doesn't exist or the new name is empty.
    @discardableResult
    public mutating func renamePointerPreset(id: String, to name: String) -> Bool {
        guard let index = pointerPresets.firstIndex(where: { $0.id == id }), !PointerPreset.cleanedName(name).isEmpty else { return false }
        pointerPresets[index].name = uniquePresetName(name, excluding: id)
        return true
    }

    /// Removes a preset. The speed stays as it is; if the preset was active it now counts as "Custom".
    /// Use `WhiskerSettings.deletePointerPreset` to also drop the buttons that switch to it.
    @discardableResult
    public mutating func deletePointerPreset(id: String) -> Bool {
        guard let index = pointerPresets.firstIndex(where: { $0.id == id }) else { return false }
        pointerPresets.remove(at: index)
        if activePointerPresetID == id { activePointerPresetID = nil }
        return true
    }

    /// Switches the custom speed to a preset. Acceleration and linear movement stay as they are. False when
    /// no custom speed is on or the preset doesn't exist.
    @discardableResult
    public mutating func selectPointerPreset(id: String) -> Bool {
        guard var current = pointer, let preset = pointerPreset(id: id) else { return false }
        current.speed = PointerMath.speedRange.clamp(preset.speed)
        pointer = current
        activePointerPresetID = id
        return true
    }

    /// A speed chosen by hand: no preset is in use any more.
    public mutating func setPointerSpeed(_ speed: Double) {
        guard var current = pointer else { return }
        current.speed = speed
        pointer = current
        activePointerPresetID = nil
    }

    /// Back to the system's own speed.
    public mutating func useSystemPointer() {
        pointerSelection = .system
    }
}

extension WhiskerSettings {
    public func pointerPreset(deviceID: String, presetID: String) -> PointerPreset? {
        devices[deviceID]?.pointerPreset(id: presetID)
    }

    /// "Fast — ×1.5 · MX Master" for a Buttons mapping. Nil when the mouse or preset doesn't exist.
    public func pointerPresetTitle(deviceID: String, presetID: String) -> String? {
        guard let device = devices[deviceID], let preset = device.pointerPreset(id: presetID) else { return nil }
        return device.name.isEmpty ? preset.label : "\(preset.label) · \(device.name)"
    }

    /// What an action does, in a few words. Like `Action.summary`, but a pointer speed preset names the speed
    /// and the mouse.
    public func summary(of action: Action) -> String {
        if case let .pointerPreset(deviceID, presetID) = action,
           let title = pointerPresetTitle(deviceID: deviceID, presetID: presetID) {
            return "Pointer speed: \(title)"
        }
        return action.summary
    }

    /// The first saved preset, for a new mapping to start from. Devices are tried in name order.
    public func firstPointerPreset() -> (deviceID: String, presetID: String)? {
        for (id, device) in devices.sorted(by: { ($0.value.name, $0.key) < ($1.value.name, $1.key) }) {
            if let preset = device.pointerPresets.first { return (id, preset.id) }
        }
        return nil
    }

    /// Mappings, in every profile, that switch `deviceID` to `presetID`.
    public func mappingCount(usingPointerPreset presetID: String, on deviceID: String) -> Int {
        let action = Action.pointerPreset(deviceID: deviceID, presetID: presetID)
        return profiles.reduce(0) { $0 + $1.mappings.filter { $0.action == action }.count }
    }

    /// Deletes a preset and the mappings that switch to it, so no button is left pointing at nothing.
    /// Returns how many mappings went with it, or nil when the preset doesn't exist.
    @discardableResult
    public mutating func deletePointerPreset(id presetID: String, on deviceID: String) -> Int? {
        guard devices[deviceID]?.deletePointerPreset(id: presetID) == true else { return nil }
        let action = Action.pointerPreset(deviceID: deviceID, presetID: presetID)
        var removed = 0
        for index in profiles.indices {
            let before = profiles[index].mappings.count
            profiles[index].mappings.removeAll { $0.action == action }
            removed += before - profiles[index].mappings.count
        }
        return removed
    }

    /// Forgets a mouse and the mappings that switch it to a preset, so none of them is left pointing at it.
    public mutating func forgetDevice(id deviceID: String) {
        devices[deviceID] = nil
        for index in profiles.indices {
            profiles[index].mappings.removeAll { mapping in
                if case .pointerPreset(let target, _) = mapping.action { return target == deviceID }
                return false
            }
        }
    }

    /// Whether a switch to this preset may go ahead right now, given the devices that are connected; nil when
    /// it may. Pure checks only: a pending confirmation and the hardware's answer are the app's to add.
    public func pointerPresetRefusal(deviceID: String, presetID: String, connected: [PointingDevice]) -> PointerPresetRefusal? {
        guard general.enabled else { return .whiskerOff }
        guard let device = devices[deviceID] else { return .unknownDevice }
        guard device.enabled else { return .deviceOff }
        guard device.pointerPresets.filter({ $0.id == presetID }).count == 1 else { return .unknownPreset }
        guard device.pointer != nil else { return .customSpeedOff }
        return PointerPresetRefusal.targetRefusal(deviceID: deviceID, connected: connected)
    }
}

extension PointerPresetRefusal {
    /// Whether `deviceID` is one connected mouse that Whisker may change: nil when it is, otherwise why it isn't.
    public static func targetRefusal(deviceID: String, connected: [PointingDevice]) -> PointerPresetRefusal? {
        let matches = connected.filter { $0.id == deviceID }
        guard let match = matches.first else { return .notConnected }
        guard matches.count == 1, match.physicalKeys.count <= 1 else { return .ambiguousDevice }
        guard !match.isExcluded else { return .excludedDevice }
        return nil
    }
}
