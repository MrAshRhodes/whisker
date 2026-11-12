import Foundation

public struct ValidationIssue: Equatable, Sendable, CustomStringConvertible {
    /// Where the problem is, e.g. `profiles[1].mappings[0]`.
    public var path: String
    public var message: String

    public init(_ path: String, _ message: String) {
        self.path = path
        self.message = message
    }

    public var description: String { "\(path): \(message)" }
}

extension WhiskerSettings {
    /// Every rule a settings file must meet. An empty array means the settings are safe to use as they are.
    public func validate() -> [ValidationIssue] {
        repairedWithIssues().issues
    }

    /// A copy with every problem fixed: out-of-range values clamped, broken mappings and profiles dropped,
    /// a default profile added if missing. Used when loading a damaged file.
    public func repaired() -> WhiskerSettings {
        repairedWithIssues().settings
    }

    public func repairedWithIssues() -> (settings: WhiskerSettings, issues: [ValidationIssue]) {
        var issues: [ValidationIssue] = []
        var result = self

        if schemaVersion != Self.currentSchemaVersion {
            issues.append(ValidationIssue("schemaVersion", "Expected \(Self.currentSchemaVersion), found \(schemaVersion)."))
            result.schemaVersion = Self.currentSchemaVersion
        }

        // Bypass list: bundle identifiers only, each once. "*" isn't an app; the master switch covers everywhere.
        var bypassApps: [String] = []
        for (index, entry) in general.bypassApps.enumerated() {
            let path = "general.bypassApps[\(index)]"
            let id = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            if id.isEmpty {
                issues.append(ValidationIssue(path, "Not an application identifier (expected a bundle identifier such as com.example.app)."))
            } else if id == ProfileMatch.any {
                issues.append(ValidationIssue(path, "“*” isn't an application. Turn Whisker off to stop it everywhere."))
            } else if bypassApps.contains(id) {
                issues.append(ValidationIssue(path, "“\(id)” is already on the list."))
            } else {
                if id != entry { issues.append(ValidationIssue(path, "Has spaces around the identifier.")) }
                bypassApps.append(id)
            }
        }
        result.general.bypassApps = bypassApps

        // Devices.
        for (id, device) in devices.sorted(by: { $0.key < $1.key }) {
            let path = "devices[\(id)]"
            guard DeviceIdentity(id: id) != nil else {
                issues.append(ValidationIssue(path, "Not a device identifier (expected vendor:product in hex)."))
                result.devices[id] = nil
                continue
            }
            if let pointer = device.pointer {
                var fixed = pointer
                fixed.speed = PointerMath.speedRange.clamp(pointer.speed)
                fixed.acceleration = PointerMath.accelerationRange.clamp(pointer.acceleration)
                if fixed.speed != pointer.speed || !pointer.speed.isFinite {
                    issues.append(ValidationIssue("\(path).pointer.speed", "Must be between \(PointerMath.speedRange.lowerBound) and \(PointerMath.speedRange.upperBound)."))
                }
                if fixed.acceleration != pointer.acceleration || !pointer.acceleration.isFinite {
                    issues.append(ValidationIssue("\(path).pointer.acceleration", "Must be between \(PointerMath.accelerationRange.lowerBound) and \(PointerMath.accelerationRange.upperBound)."))
                }
                result.devices[id]?.pointer = fixed
            }
            if var native = device.wheel.native {
                if let speed = native.speed, !NativeWheelMath.speedRange.contains(speed) {
                    issues.append(ValidationIssue("\(path).wheel.native.speed", "Must be between \(NativeWheelMath.speedRange.lowerBound) and \(NativeWheelMath.speedRange.upperBound)."))
                    native.speed = speed.isFinite ? NativeWheelMath.speedRange.clamp(speed) : nil
                }
                if let acceleration = native.acceleration, !NativeWheelMath.accelerationRange.contains(acceleration) {
                    issues.append(ValidationIssue("\(path).wheel.native.acceleration", "Must be between \(NativeWheelMath.accelerationRange.lowerBound) and \(NativeWheelMath.accelerationRange.upperBound)."))
                    native.acceleration = acceleration.isFinite ? NativeWheelMath.accelerationRange.clamp(acceleration) : nil
                }
                result.devices[id]?.wheel.native = native
            }
            var labels: [ControlLabel] = []
            for (index, label) in device.controlLabels.enumerated() {
                let labelPath = "\(path).controlLabels[\(index)]"
                if case .button(let number) = label.trigger, !Trigger.buttonRange.contains(number) {
                    issues.append(ValidationIssue(labelPath, "Button numbers run from 0 to 31."))
                } else if labels.contains(where: { $0.trigger == label.trigger }) {
                    issues.append(ValidationIssue(labelPath, "\(label.trigger.title) already has a label."))
                } else if let name = ControlLabel.normalised(label.name) {
                    if name != label.name { issues.append(ValidationIssue(labelPath, "Label was trimmed or shortened to \(ControlLabel.maxLength) characters.")) }
                    labels.append(ControlLabel(trigger: label.trigger, name: name))
                } else {
                    issues.append(ValidationIssue(labelPath, "A label needs a name."))
                }
            }
            result.devices[id]?.controlLabels = labels
            if let current = result.devices[id] {
                result.devices[id] = Self.repairPresets(of: current, path: path, issues: &issues)
            }
        }

        for (id, device) in result.devices.sorted(by: { $0.key < $1.key }) {
            guard let debounce = device.clickDebounce else { continue }
            let path = "devices[\(id)].clickDebounce"
            let fixed = debounce.normalised
            let range = ClickDebounceSettings.intervalRange
            if !debounce.interval.isFinite || !range.contains(debounce.interval) {
                issues.append(ValidationIssue("\(path).interval", "Must be between \(range.lowerBound) and \(range.upperBound) seconds."))
            }
            if fixed.buttons != debounce.buttons {
                issues.append(ValidationIssue("\(path).buttons", "Must list each button once, numbered \(ClickDebounceSettings.buttonRange.lowerBound) to \(ClickDebounceSettings.buttonRange.upperBound)."))
            }
            result.devices[id]?.clickDebounce = fixed
        }

        // Profiles.
        var seenIDs = Set<String>()
        var profiles: [Profile] = []
        for (index, profile) in self.profiles.enumerated() {
            let path = "profiles[\(index)]"
            guard !profile.id.isEmpty else {
                issues.append(ValidationIssue(path, "Profile has no id."))
                continue
            }
            guard seenIDs.insert(profile.id).inserted else {
                issues.append(ValidationIssue(path, "Another profile already uses the id “\(profile.id)”."))
                continue
            }
            if profile.match.devices.isEmpty || profile.match.apps.isEmpty {
                issues.append(ValidationIssue("\(path).match", "A profile must match at least one device and one app (use “*” for any)."))
            }
            profiles.append(Self.repair(profile, path: path, allowPrimary: general.allowPrimaryButtonRemap, devices: result.devices, issues: &issues))
        }

        if !profiles.contains(where: \.isDefault) {
            issues.append(ValidationIssue("profiles", "The default profile is missing."))
            profiles.insert(.makeDefault(), at: 0)
        } else if let index = profiles.firstIndex(where: \.isDefault), index != 0 {
            profiles.insert(profiles.remove(at: index), at: 0)
        }
        if let index = profiles.firstIndex(where: \.isDefault), profiles[index].match != ProfileMatch() {
            issues.append(ValidationIssue("profiles[\(index)].match", "The default profile must match every device and app."))
            profiles[index].match = ProfileMatch()
        }
        for i in profiles.indices {
            var ensured = profiles[i].match
            if ensured.devices.isEmpty { ensured.devices = [ProfileMatch.any] }
            if ensured.apps.isEmpty { ensured.apps = [ProfileMatch.any] }
            profiles[i].match = ensured
        }

        // Inheritance: parents must exist and must not loop back.
        let ids = Set(profiles.map(\.id))
        for i in profiles.indices {
            guard let parent = profiles[i].inherits else { continue }
            if !ids.contains(parent) {
                issues.append(ValidationIssue("profiles[\(i)].inherits", "No profile has the id “\(parent)”."))
                profiles[i].inherits = Profile.defaultID
            }
        }
        for i in profiles.indices where Self.inheritanceLoops(from: profiles[i].id, in: profiles) {
            issues.append(ValidationIssue("profiles[\(i)].inherits", "Inheritance loops back to “\(profiles[i].id)”."))
            profiles[i].inherits = profiles[i].isDefault ? nil : Profile.defaultID
            if Self.inheritanceLoops(from: profiles[i].id, in: profiles) { profiles[i].inherits = nil }
        }

        result.profiles = profiles
        return (result, issues)
    }

    /// Fixes one device's presets: drops the ones that can't be addressed (no id, a repeated id, over the limit),
    /// clamps speeds, gives nameless presets a name, and forgets an active preset that isn't usable.
    private static func repairPresets(of device: DeviceSettings, path: String, issues: inout [ValidationIssue]) -> DeviceSettings {
        var device = device
        var seen = Set<String>()
        var kept: [PointerPreset] = []
        for (index, preset) in device.pointerPresets.enumerated() {
            let presetPath = "\(path).pointerPresets[\(index)]"
            guard !preset.id.isEmpty else {
                issues.append(ValidationIssue(presetPath, "Preset has no id."))
                continue
            }
            guard seen.insert(preset.id).inserted else {
                issues.append(ValidationIssue(presetPath, "Another preset already uses the id “\(preset.id)”."))
                continue
            }
            guard kept.count < PointerPreset.maxPerDevice else {
                issues.append(ValidationIssue(presetPath, "A mouse can have at most \(PointerPreset.maxPerDevice) presets."))
                continue
            }
            var fixed = preset
            fixed.speed = PointerMath.speedRange.clamp(preset.speed)
            if fixed.speed != preset.speed || !preset.speed.isFinite {
                issues.append(ValidationIssue("\(presetPath).speed", "Must be between \(PointerMath.speedRange.lowerBound) and \(PointerMath.speedRange.upperBound)."))
            }
            let name = PointerPreset.cleanedName(preset.name)
            if name.isEmpty {
                issues.append(ValidationIssue("\(presetPath).name", "A preset needs a name."))
                fixed.name = PointerPreset.defaultName
            } else {
                if preset.name.count > PointerPreset.maxNameLength || preset.name.contains(where: \.isNewline) {
                    issues.append(ValidationIssue("\(presetPath).name", "A name is one line of at most \(PointerPreset.maxNameLength) characters."))
                }
                fixed.name = name
            }
            kept.append(fixed)
        }
        device.pointerPresets = kept
        if let active = device.activePointerPresetID {
            if !kept.contains(where: { $0.id == active }) {
                issues.append(ValidationIssue("\(path).activePointerPresetID", "No preset has the id “\(active)”."))
                device.activePointerPresetID = nil
            } else if device.pointer == nil {
                issues.append(ValidationIssue("\(path).activePointerPresetID", "A preset is only in use while a custom pointer speed is on."))
                device.activePointerPresetID = nil
            }
        }
        return device
    }

    private static func repair(_ profile: Profile, path: String, allowPrimary: Bool, devices: [String: DeviceSettings], issues: inout [ValidationIssue]) -> Profile {
        var profile = profile
        if var scroll = profile.scroll {
            if let lines = scroll.linesPerNotch, !ScrollMath.linesRange.contains(lines) {
                issues.append(ValidationIssue("\(path).scroll.linesPerNotch", "Must be between \(ScrollMath.linesRange.lowerBound) and \(ScrollMath.linesRange.upperBound)."))
                scroll.linesPerNotch = ScrollMath.linesRange.clamp(lines)
            }
            let acceleration = ScrollMath.accelerationRange.clamp(scroll.acceleration)
            if acceleration != scroll.acceleration || !scroll.acceleration.isFinite {
                issues.append(ValidationIssue("\(path).scroll.acceleration", "Must be between 0 and 1."))
                scroll.acceleration = acceleration
            }
            let duration = ScrollMath.smoothDurationRange.clamp(scroll.smoothDuration)
            if duration != scroll.smoothDuration {
                let range = ScrollMath.smoothDurationRange
                issues.append(ValidationIssue("\(path).scroll.smoothDuration", "Must be between \(range.lowerBound) and \(range.upperBound) milliseconds."))
                scroll.smoothDuration = duration
            }
            if let scaling = scroll.modifierScaling {
                let scalingPath = "\(path).scroll.modifierScaling"
                if let problem = scaling.problem(horizontalModifier: scroll.horizontalModifier) {
                    issues.append(ValidationIssue(scalingPath, problem))
                    scroll.modifierScaling = nil
                } else {
                    let multiplier = ScrollMath.multiplierRange.clamp(scaling.multiplier)
                    if multiplier != scaling.multiplier {
                        let range = ScrollMath.multiplierRange
                        issues.append(ValidationIssue("\(scalingPath).multiplier", "Must be between \(String(format: "%g", range.lowerBound)) and \(String(format: "%g", range.upperBound))."))
                        scroll.modifierScaling?.multiplier = multiplier
                    }
                }
            }
            profile.scroll = scroll
        }

        var seenKeys = Set<MappingKey>()
        var kept: [Mapping] = []
        for (index, original) in profile.mappings.enumerated() {
            var mapping = original
            let mappingPath = "\(path).mappings[\(index)]"
            if let problem = problem(with: mapping, allowPrimary: allowPrimary) {
                issues.append(ValidationIssue(mappingPath, problem))
                continue
            }
            if case let .pointerPreset(deviceID, presetID) = mapping.action, devices[deviceID]?.pointerPreset(id: presetID) == nil {
                issues.append(ValidationIssue(mappingPath, "The pointer speed preset doesn’t exist for that mouse."))
                continue
            }
            guard seenKeys.insert(mapping.key).inserted else {
                issues.append(ValidationIssue(mappingPath, "\(mapping.key.title) is already mapped in this profile."))
                continue
            }
            if let continuous = mapping.continuousInput {
                if mapping.trigger != .wheel(.left), mapping.trigger != .wheel(.right) {
                    issues.append(ValidationIssue("\(mappingPath).continuousInput", "Smooth scrolling only applies to Scroll Left and Scroll Right."))
                    mapping.continuousInput = nil
                } else if !ContinuousWheelInput.distanceRange.contains(continuous.distance) {
                    let range = ContinuousWheelInput.distanceRange
                    issues.append(ValidationIssue("\(mappingPath).continuousInput.distance", "Must be between \(String(format: "%g", range.lowerBound)) and \(String(format: "%g", range.upperBound))."))
                    mapping.continuousInput?.distance = continuous.effectiveDistance
                }
            }
            kept.append(mapping)
        }
        profile.mappings = kept
        return profile
    }

    /// Why a single mapping can't be used, or nil when it is fine.
    public static func problem(with mapping: Mapping, allowPrimary: Bool) -> String? {
        switch mapping.trigger {
        case .button(let number):
            guard Trigger.buttonRange.contains(number) else { return "Button numbers run from 0 to 31." }
            if number == 0, mapping.modifiers.isEmpty, !allowPrimary, mapping.action != .passthrough {
                return "The primary button can only be remapped with a modifier key, unless remapping it is turned on in General."
            }
        case .wheel:
            break
        }
        switch mapping.action {
        case .click(let button, _):
            guard Trigger.buttonRange.contains(button) else { return "Click buttons run from 0 to 31." }
        case .scroll(_, let lines):
            guard ScrollMath.linesRange.contains(lines) else { return "Scroll distance must be 1 to 20 lines." }
        case .holdToScroll(let config):
            let range = HoldScroll.sensitivityRange
            guard config.isValid else { return "Hold to Scroll sensitivity must be between \(String(format: "%g", range.lowerBound)) and \(String(format: "%g", range.upperBound))." }
        case .shortcut(let shortcut, _):
            guard shortcut.keyCode < 0x80 else { return "Key code \(shortcut.keyCode) is not a key." }
        case .shortcutSequence(let steps):
            if let problem = ShortcutSequenceLimits.problem(with: steps) { return problem }
        case .open(let url):
            guard Action.openURL(for: url) != nil else { return "“\(url)” is not an app, file or web address." }
        case let .pointerPreset(deviceID, presetID):
            guard DeviceIdentity(id: deviceID) != nil else { return "Choose a mouse for the pointer speed preset." }
            guard !presetID.isEmpty else { return "Choose a pointer speed preset." }
        default:
            break
        }
        return nil
    }

    static func inheritanceLoops(from id: String, in profiles: [Profile]) -> Bool {
        let parents = Dictionary(profiles.map { ($0.id, $0.inherits) }, uniquingKeysWith: { first, _ in first })
        var visited: Set<String> = [id]
        var current = parents[id] ?? nil
        while let next = current {
            if next == id { return true }
            if !visited.insert(next).inserted { return false }
            current = parents[next] ?? nil
        }
        return false
    }
}

extension ClosedRange where Bound: Comparable {
    func clamp(_ value: Bound) -> Bound {
        Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}

extension ClosedRange where Bound == Double {
    func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return lowerBound }
        return Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}
