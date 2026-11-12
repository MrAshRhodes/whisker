import Foundation

/// Trading places of a mouse's primary and secondary buttons.
///
/// The two buttons swap as one pair or not at all. A press is swapped only when Whisker is sure which mouse
/// pressed it, that mouse is set to swap, no modifier key is held, and no profile that applies maps the plain
/// primary or secondary button itself: such a mapping says exactly what the button does, so the swap stands
/// aside for it. Other buttons and modified clicks are left as they are.
public enum ButtonSwap {
    /// The two buttons that trade places: the primary button is 0 and the secondary button is 1.
    static let pair = [0, 1]

    /// The button a press of `button` is delivered as, or nil for a button outside the pair.
    public static func counterpart(of button: Int) -> Int? {
        switch button {
        case 0: return 1
        case 1: return 0
        default: return nil
        }
    }

    /// The button the press in `event` is delivered as, or nil when the usual handling applies. The caller has
    /// already checked that Whisker, the mouse and the app in front allow mapping at all.
    public static func target(of button: Int, in event: InputEvent, settings: CompiledSettings) -> Int? {
        guard !settings.swappedDevices.isEmpty, let target = counterpart(of: button),
              let device = event.device, device.exact, !device.isExcluded, settings.swappedDevices.contains(device.id),
              settings.general.allowPrimaryButtonRemap, event.modifiers.withoutFunction.isEmpty else { return nil }
        return mapsPair(settings.profile(device: device.id, app: event.app)) ? nil : target
    }

    /// Whether the profile maps the plain primary or secondary button, whatever it maps it to (even "Pass Through").
    static func mapsPair(_ profile: ResolvedProfile) -> Bool {
        pair.contains { profile.mapping(.button($0), modifiers: []) != nil }
    }

    /// Whether the swap is doing anything for a mouse and, if not, what is in the way. For the settings window.
    ///
    /// `canIdentifyPresses` is whether Whisker can tell which mouse a press came from at all, which needs Input
    /// Monitoring; without it a press is never certain enough to swap.
    public static func status(for deviceID: String, in settings: WhiskerSettings, canIdentifyPresses: Bool) -> ButtonSwapStatus {
        let device = settings.device(deviceID)
        guard device.swapPrimarySecondary else { return ButtonSwapStatus(phase: .off, mappedBy: []) }

        // Every profile that can apply to this mouse, in some app or other, and who defines the mappings in the way.
        let candidates = [settings.defaultProfile] + settings.profiles.filter {
            !$0.isDefault && ($0.match.devices.contains(deviceID) || $0.match.devices.contains(ProfileMatch.any))
        }
        var owners: [String] = []
        var someProfileIsFree = false
        for candidate in candidates {
            let resolved = settings.resolvedProfile(id: candidate.id)
            let defining = pair.compactMap { resolved.mappings[MappingKey(.button($0))]?.sourceProfileID }
            if defining.isEmpty { someProfileIsFree = true }
            for id in defining where !owners.contains(id) { owners.append(id) }
        }
        let names = owners.compactMap { id in id == Profile.defaultID ? settings.defaultProfile.name : settings.profile(id: id)?.name }

        let phase: ButtonSwapStatus.Phase
        if !settings.general.enabled {
            phase = .inactive(.whiskerOff)
        } else if !device.enabled {
            phase = .inactive(.mouseOff)
        } else if !settings.general.allowPrimaryButtonRemap {
            phase = .inactive(.primaryRemapNotAllowed)
        } else if !canIdentifyPresses {
            phase = .inactive(.cannotIdentifyPresses)
        } else if !someProfileIsFree {
            phase = .inactive(.buttonsMappedEverywhere)
        } else {
            phase = .active
        }
        return ButtonSwapStatus(phase: phase, mappedBy: names)
    }
}

/// How a mouse's button swap is getting on, in terms the settings window can explain.
public struct ButtonSwapStatus: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// The mouse isn't set to swap.
        case off
        /// Presses are being swapped (except where `mappedBy` says a profile stands in the way).
        case active
        /// Set to swap, but nothing is swapped yet.
        case inactive(Reason)
    }

    public enum Reason: Equatable, Sendable {
        case whiskerOff
        case mouseOff
        /// "Allow remapping the primary button" is off, which keeps the primary button safe.
        case primaryRemapNotAllowed
        /// Whisker can't tell which mouse a press came from.
        case cannotIdentifyPresses
        /// Every profile that applies to the mouse maps the plain primary or secondary button.
        case buttonsMappedEverywhere
    }

    public var phase: Phase
    /// Names of the profiles that map the plain primary or secondary button themselves. The swap stands aside
    /// wherever one of them applies (also in profiles that inherit the mapping).
    public var mappedBy: [String]

    public init(phase: Phase, mappedBy: [String]) {
        self.phase = phase
        self.mappedBy = mappedBy
    }
}

/// The presses that were delivered as the other button and haven't been released yet, oldest first.
///
/// A release or drag follows the button its press became, whatever the settings say by then. Presses are kept
/// per mouse, so two mice holding the same button each get a release of their own.
public struct SwappedPresses: Equatable, Sendable {
    public struct Press: Equatable, Sendable {
        public var device: String
        /// The button the mouse pressed.
        public var button: Int
        /// The button it was delivered as.
        public var target: Int

        public init(device: String, button: Int, target: Int) {
            self.device = device
            self.button = button
            self.target = target
        }
    }

    public private(set) var presses: [Press] = []

    public init() {}

    public var isEmpty: Bool { presses.isEmpty }

    /// The physical buttons of the presses being swapped.
    public var buttons: Set<Int> { Set(presses.map(\.button)) }

    /// Notes a press that is delivered as `target`. One still noted for the same button of the same mouse lost its
    /// release, so it is replaced.
    public mutating func began(_ button: Int, as target: Int, from device: String) {
        presses.removeAll { $0.device == device && $0.button == button }
        presses.append(Press(device: device, button: button, target: target))
    }

    /// Forgets a press whose release never came, because the same mouse is pressing the button again. An event that
    /// isn't exactly attributed can't say which mouse it is, so it forgets nothing.
    public mutating func forget(_ button: Int, from device: DeviceAttribution?) {
        guard let device, device.exact else { return }
        presses.removeAll { $0.device == device.id && $0.button == button }
    }

    /// The button a drag of `button` is delivered as, when a press of it is being swapped.
    public func target(of button: Int, from device: DeviceAttribution?) -> Int? {
        index(of: button, from: device).map { presses[$0].target }
    }

    /// Ends the press a release of `button` belongs to and returns the button it was delivered as.
    public mutating func end(_ button: Int, from device: DeviceAttribution?) -> Int? {
        guard let index = index(of: button, from: device) else { return nil }
        return presses.remove(at: index).target
    }

    /// Ends every press.
    public mutating func removeAll() -> [Press] {
        defer { presses.removeAll() }
        return presses
    }

    /// Ends the presses of mice that are no longer among `connected`.
    public mutating func remove(unlessConnected connected: Set<String>) -> [Press] {
        let gone = presses.filter { !connected.contains($0.device) }
        presses.removeAll { !connected.contains($0.device) }
        return gone
    }

    /// The press an event belongs to. Releases and drags are rarely attributed exactly: when they are, only that
    /// mouse's press qualifies; otherwise the oldest press of the button does. Either way every release ends exactly
    /// one press, so what is delivered always balances.
    private func index(of button: Int, from device: DeviceAttribution?) -> Int? {
        if let device, device.exact { return presses.firstIndex { $0.button == button && $0.device == device.id } }
        return presses.firstIndex { $0.button == button }
    }
}
