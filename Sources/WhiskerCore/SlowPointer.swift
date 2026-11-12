import Foundation

/// A begin/end update contains the whole overlay, so a newer release supersedes every queued start.
public struct SlowPointerCommand: Equatable, Sendable {
    public var generation: UInt64
    public var factors: [String: Double]
    /// Stable through overlapping holds; changes after the last hold ends, even if its end is coalesced.
    public var sessions: [String: UInt64]

    public init(generation: UInt64, factors: [String: Double], sessions: [String: UInt64]? = nil) {
        self.generation = generation
        self.factors = factors
        self.sessions = sessions ?? factors.mapValues { _ in generation }
    }
}

public enum SlowPointer {
    public static let factorRange: ClosedRange<Double> = 0.1...0.9

    public static func isValid(_ factor: Double) -> Bool {
        factor.isFinite && factorRange.contains(factor)
    }

    public static func applying(_ factor: Double, to baseline: PointerSettings) -> PointerSettings {
        guard isValid(factor) else { return baseline }
        var result = baseline
        result.speed = PointerMath.speedRange.clamp(baseline.speed * factor)
        return result
    }
}

/// Owns physical presses, including cancelled ones whose releases must still be consumed.
public struct SlowPointerHolds: Sendable {
    private struct Owner: Hashable, Sendable {
        var device: String
        var button: Int
    }

    private struct ReleaseTails: Sendable {
        var candidates: Set<String> = []
        var remaining = 0
    }

    private var pressed: Set<Owner> = []
    private var active: [Owner: Double] = [:]
    /// Ambiguity retires live ownership, but not the releases of presses already swallowed.
    private var retired: [Int: ReleaseTails] = [:]
    private var sessions: [String: UInt64] = [:]
    public private(set) var command = SlowPointerCommand(generation: 0, factors: [:])

    public init() {}

    public func owns(button: Int, device: DeviceAttribution?) -> Bool {
        guard let device, device.exact else { return false }
        return pressed.contains(Owner(device: device.id, button: button))
    }

    public mutating func preparePress(button: Int, device: DeviceAttribution?) {
        guard let device, device.exact, var tails = retired[button] else { return }
        tails.candidates.remove(device.id)
        tails.remaining = min(tails.remaining, tails.candidates.count)
        retired[button] = tails.remaining > 0 ? tails : nil
    }

    public mutating func begin(button: Int, device: DeviceAttribution?, factor: Double, available: Set<String>) -> Bool {
        guard let device, device.exact, available.contains(device.id), SlowPointer.isValid(factor) else { return false }
        preparePress(button: button, device: device)
        let owner = Owner(device: device.id, button: button)
        guard pressed.insert(owner).inserted else { return true }
        if !active.keys.contains(where: { $0.device == device.id }) {
            sessions[device.id] = command.generation &+ 1
        }
        active[owner] = factor
        publish()
        return true
    }

    public mutating func end(button: Int, device: DeviceAttribution?) -> Bool {
        guard let device, device.exact else {
            // End every candidate's slowdown without guessing which mouse released. Keep only the number
            // of swallowed tails still owed, not ownership that would block the next real press.
            retire(pressed.filter { $0.button == button })
            guard var tails = retired[button], tails.remaining > 0 else { return false }
            tails.remaining -= 1
            retired[button] = tails.remaining > 0 ? tails : nil
            publish()
            return true
        }
        let owner = Owner(device: device.id, button: button)
        guard pressed.remove(owner) != nil else {
            guard var tails = retired[button], tails.candidates.remove(device.id) != nil else { return false }
            tails.remaining -= 1
            retired[button] = tails.remaining > 0 ? tails : nil
            return true
        }
        active[owner] = nil
        publish()
        return true
    }

    public mutating func devicesChanged(connected: Set<String>) {
        retire(pressed.filter { !connected.contains($0.device) })
        publish()
    }

    public mutating func cancel(unlessAvailable available: Set<String> = []) {
        active = active.filter { available.contains($0.key.device) }
        publish()
    }

    private mutating func retire(_ owners: Set<Owner>) {
        for owner in owners {
            var tails = retired[owner.button] ?? ReleaseTails()
            tails.candidates.insert(owner.device)
            tails.remaining += 1
            retired[owner.button] = tails
            pressed.remove(owner)
            active[owner] = nil
        }
    }

    private mutating func publish() {
        var factors: [String: Double] = [:]
        for (owner, factor) in active {
            factors[owner.device] = min(factors[owner.device] ?? 1, factor)
        }
        sessions = sessions.filter { factors[$0.key] != nil }
        command = SlowPointerCommand(generation: command.generation &+ 1, factors: factors, sessions: sessions)
    }
}
